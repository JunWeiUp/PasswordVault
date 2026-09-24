import XCTest

final class VaultFlowTests: XCTestCase {
  func testCreateNoteDeleteAndRestore() {
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
    app.buttons["新建"].tap()
    let title = app.textFields["entry.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("UI test note")
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts["UI test note"].waitForExistence(timeout: 5))
    app.staticTexts["UI test note"].firstMatch.tap()
    app.buttons["移到回收站…"].tap()
    app.buttons["删除"].tap()
    // Deletion persists asynchronously and then dismisses the detail page.
    // Waiting for XCTest idleness alone does not wait for that Swift Task.
    let notesNavigation = app.navigationBars["全部笔记"]
    XCTAssertTrue(notesNavigation.buttons["新建"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitFor(app.staticTexts["UI test note"].firstMatch, "exists == false"))
    let settings = app.tabBars.buttons["设置"]
    settings.tap()
    XCTAssertTrue(waitFor(settings, "selected == true"), "Settings must be selected before opening Trash")
    let trash = app.buttons["回收站"]
    XCTAssertTrue(trash.waitForExistence(timeout: 5))
    trash.tap()
    XCTAssertTrue(app.staticTexts["UI test note"].waitForExistence(timeout: 5))
    app.staticTexts["UI test note"].firstMatch.tap()
    app.buttons["恢复"].tap()
    XCTAssertTrue(app.navigationBars["回收站"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitFor(app.staticTexts["UI test note"].firstMatch, "exists == false"))
    let notes = app.tabBars.buttons["全部笔记"]
    notes.tap()
    XCTAssertTrue(waitFor(notes, "selected == true"))
    XCTAssertTrue(app.staticTexts["UI test note"].waitForExistence(timeout: 5))
    app.buttons["锁定"].tap()
    XCTAssertTrue(app.secureTextFields["vault.password"].waitForExistence(timeout: 5))
  }
  func testBackgroundPreservesEncryptedDraft() {
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
    app.buttons["新建"].tap()
    let title = app.textFields["entry.title"]
    title.tap()
    title.typeText("Unfinished encrypted draft")
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(password.waitForExistence(timeout: 10))
    password.tap()
    password.typeText("1")
    app.buttons["vault.unlock"].tap()
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    XCTAssertEqual(title.value as? String, "Unfinished encrypted draft")
    app.buttons["保存"].tap()
    app.tabBars.buttons["全部笔记"].tap()
    XCTAssertTrue(app.staticTexts["Unfinished encrypted draft"].waitForExistence(timeout: 5))
  }

  private func waitFor(_ element: XCUIElement, _ predicate: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }
}
