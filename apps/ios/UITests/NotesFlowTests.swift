import XCTest

/// Notes: grid and list layouts, name sort, and the read-only page with an Edit button.
final class NotesFlowTests: XCTestCase {
  func testGridListSortAndReadingPage() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-vault", UUID().uuidString]
    app.launch()
    let password = app.secureTextFields["vault.password"]
    XCTAssertTrue(password.waitForExistence(timeout: 10))
    password.tap()
    password.typeText("1")
    let confirm = app.secureTextFields.element(boundBy: 1)
    confirm.tap()
    confirm.typeText("1")
    app.buttons["vault.unlock"].tap()
    XCTAssertTrue(app.tabBars.buttons["全部笔记"].waitForExistence(timeout: 10))
    app.tabBars.buttons["全部笔记"].tap()

    for name in ["Bravo note", "Alpha note"] {
      app.buttons["新建"].tap()
      XCTAssertTrue(app.buttons["新建条目"].waitForExistence(timeout: 5))
      app.buttons["新建条目"].tap()
      let title = app.textFields["entry.title"]
      XCTAssertTrue(title.waitForExistence(timeout: 5))
      title.tap()
      title.typeText(name)
      XCTAssertTrue(waitFor(app.buttons["保存"], "isEnabled == true"))
      app.buttons["保存"].tap()
      XCTAssertTrue(waitFor(title, "exists == false"))
    }
    let alpha = app.staticTexts["Alpha note"].firstMatch
    let bravo = app.staticTexts["Bravo note"].firstMatch
    XCTAssertTrue(alpha.waitForExistence(timeout: 10))
    XCTAssertTrue(bravo.waitForExistence(timeout: 10))
    // Default grid, newest first: Alpha (left) then Bravo (right) on one row.
    XCTAssertLessThan(alpha.frame.minX, bravo.frame.minX)
    XCTAssertEqual(alpha.frame.minY, bravo.frame.minY, accuracy: 4)

    app.buttons["显示选项"].tap()
    app.buttons["名称"].tap()
    app.buttons["显示选项"].tap()
    app.buttons["列表"].tap()
    XCTAssertTrue(waitFor(alpha, "exists == true"))
    XCTAssertLessThan(alpha.frame.minY, bravo.frame.minY, "List sorted by name")
    app.buttons["显示选项"].tap()
    app.buttons["网格"].tap()
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "notes-grid"
    shot.lifetime = .keepAlways
    add(shot)

    alpha.tap()
    XCTAssertTrue(app.staticTexts["note.reader.title"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["note.reader.title"].label, "Alpha note")
    XCTAssertFalse(app.textFields["entry.title"].exists, "The reading page is read-only")
    app.navigationBars.buttons["编辑"].tap()
    XCTAssertTrue(app.textFields["entry.title"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    app.buttons["放弃修改"].tap()
    XCTAssertTrue(waitFor(app.textFields["entry.title"], "exists == false"))
    XCTAssertTrue(app.staticTexts["note.reader.title"].exists)
  }

  private func waitFor(_ element: XCUIElement, _ predicate: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }
}
