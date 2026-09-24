import XCTest

final class TabletFlowTests: XCTestCase {
  func testSidebarAndEditorInLandscape() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout test") }
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-vault", UUID().uuidString]
    app.launch()
    let password = app.secureTextFields["vault.password"]
    XCTAssertTrue(password.waitForExistence(timeout: 10))
    password.tap()
    password.typeText("Tablet QA only 123!")
    let confirmation = app.secureTextFields.element(boundBy: 1)
    confirmation.tap()
    confirmation.typeText("Tablet QA only 123!")
    app.buttons["vault.unlock"].tap()
    let notes = app.buttons["全部笔记"].firstMatch
    XCTAssertTrue(notes.waitForExistence(timeout: 10))
    notes.tap()
    app.buttons["新建"].tap()
    let title = app.textFields["entry.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Home reference")
    app.textViews["备注"].tap()
    app.textViews["备注"].typeText(
      "# Household reference\n\nFictional information for layout review.\n\n- Documents: second shelf\n- Network: Home-Example\n\nAccount credentials are stored in Passwords."
    )
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts["Home reference"].firstMatch.waitForExistence(timeout: 5))
    app.staticTexts["Home reference"].firstMatch.tap()
    XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
    XCTAssertTrue(app.buttons["设置"].firstMatch.isHittable)
  }
}
