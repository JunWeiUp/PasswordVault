import XCTest

/// Notes: grid and list layouts, name sort, and the read-only page with an Edit button.
final class NotesFlowTests: XCTestCase {
  func testGridListSortAndReadingPage() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-vault", UUID().uuidString]
    app.launch()
    // First run opens on the welcome step.
    let start = app.buttons["onboarding.start"]
    if start.waitForExistence(timeout: 10) { start.tap() }
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

  /// Multi-select: favorite and move to a category, the richer context menu, then Trash.
  func testMultiSelectContextMenuAndTrash() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-vault", UUID().uuidString]
    app.launch()
    // First run opens on the welcome step.
    let start = app.buttons["onboarding.start"]
    if start.waitForExistence(timeout: 10) { start.tap() }
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
    XCTAssertFalse(app.descendants(matching: .any)["relay.offline"].exists, "No banner without a device group")

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
    XCTAssertTrue(app.staticTexts["Alpha note"].firstMatch.waitForExistence(timeout: 10))

    // Context menu on a grid card.
    app.staticTexts["Alpha note"].firstMatch.press(forDuration: 1.2)
    for label in ["编辑", "置顶", "收藏", "移动到分类…", "版本历史", "移到回收站…"] {
      XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), label)
    }
    attach(app, "notes-context-menu")
    app.buttons["版本历史"].tap()
    XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
    app.buttons["完成"].tap()

    // Select both notes; favorite them, then move them to a new category.
    app.buttons["selection.start"].tap()
    XCTAssertTrue(app.staticTexts["已选择 0 项"].waitForExistence(timeout: 5))
    app.buttons["全选"].tap()
    XCTAssertTrue(app.staticTexts["已选择 2 项"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The tab bar hides while selecting")
    attach(app, "notes-selecting")
    app.buttons["selection.favorite"].tap()
    XCTAssertTrue(app.buttons["selection.start"].waitForExistence(timeout: 10), "Selection ends after the action")
    app.buttons["显示选项"].tap()
    app.buttons["列表"].tap()
    XCTAssertTrue(waitFor(app.images.matching(NSPredicate(format: "label CONTAINS[c] 'star' OR identifier CONTAINS[c] 'star'")).element(boundBy: 1), "exists == true"))

    app.buttons["selection.start"].tap()
    app.staticTexts["Alpha note"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["已选择 1 项"].waitForExistence(timeout: 5))
    app.buttons["selection.move"].tap()
    let name = app.textFields["category.name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText("Travel")
    app.buttons["移动到新分类"].tap()
    XCTAssertTrue(app.buttons["Travel"].waitForExistence(timeout: 10), "The new category chip appears")

    // Move everything to Trash in one step.
    app.buttons["selection.start"].tap()
    app.buttons["全选"].tap()
    app.buttons["selection.trash"].tap()
    let trash = app.buttons["移到回收站"].firstMatch
    XCTAssertTrue(trash.waitForExistence(timeout: 5))
    trash.tap()
    XCTAssertTrue(app.staticTexts["这里还没有笔记"].waitForExistence(timeout: 10))
    attach(app, "notes-trashed")
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func waitFor(_ element: XCUIElement, _ predicate: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }
}
