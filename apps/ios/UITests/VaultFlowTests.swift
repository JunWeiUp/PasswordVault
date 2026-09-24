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
    app.tabBars.buttons["设置"].tap()
    app.buttons["回收站"].tap()
    XCTAssertTrue(app.staticTexts["UI test note"].waitForExistence(timeout: 5))
    app.staticTexts["UI test note"].firstMatch.tap()
    app.buttons["恢复"].tap()
    app.tabBars.buttons["全部笔记"].tap()
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

}
