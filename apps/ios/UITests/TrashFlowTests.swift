import XCTest

/// Trash: undo after moving an entry, the retention notice, and Empty Trash with confirmation.
final class TrashFlowTests: XCTestCase {
  func testUndoAndEmptyTrash() {
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

    XCTAssertTrue(app.tabBars.buttons["密码"].waitForExistence(timeout: 10))
    app.tabBars.buttons["密码"].tap()
    app.buttons["新建"].tap()
    app.buttons["新建条目"].tap()
    let title = app.textFields["entry.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Trash fixture")
    XCTAssertTrue(waitFor(app.buttons["保存"], "isEnabled == true"))
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons["Trash fixture"].firstMatch.waitForExistence(timeout: 10))

    // Move to Trash, then undo from the banner.
    app.buttons["Trash fixture"].firstMatch.tap()
    app.buttons["移到回收站…"].tap()
    app.buttons["删除"].tap()
    let undo = app.buttons["undo.trash"]
    XCTAssertTrue(undo.waitForExistence(timeout: 10))
    undo.tap()
    XCTAssertTrue(app.buttons["Trash fixture"].firstMatch.waitForExistence(timeout: 10), "Undo restores the entry")

    // Move it again and let the banner go.
    app.buttons["Trash fixture"].firstMatch.tap()
    app.buttons["移到回收站…"].tap()
    app.buttons["删除"].tap()
    XCTAssertTrue(waitFor(app.buttons["Trash fixture"].firstMatch, "exists == false"))

    app.tabBars.buttons["设置"].tap()
    app.buttons["回收站"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '直到你永久删除或清空'")).firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Trash fixture"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["清空回收站…"].tap()
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '将永久删除 1 个项目'")).firstMatch.waitForExistence(timeout: 5))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "empty-trash-confirmation"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["永久删除 1 项"].tap()
    XCTAssertTrue(app.staticTexts["回收站是空的"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["Trash fixture"].exists)
  }

  private func waitFor(_ element: XCUIElement, _ predicate: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }
}
