import XCTest

/// Devices & services: read-only list and detail, hidden secrets, SSH command and share button.
final class DevicesFlowTests: XCTestCase {
  func testReadOnlyDeviceDetail() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-vault", UUID().uuidString, "--ui-test-device-fixture"]
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

    XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 10))
    app.tabBars.buttons["设置"].tap()
    app.staticTexts["设备与服务"].firstMatch.tap()
    let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Fixture server'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()

    let host = app.staticTexts["device.field.host"]
    XCTAssertTrue(host.waitForExistence(timeout: 5))
    XCTAssertEqual(host.label, "server.example.test")
    let secret = app.staticTexts["device.field.password"]
    XCTAssertEqual(secret.label, "••••••••••••", "The password is hidden by default")
    XCTAssertFalse(app.staticTexts["SYNTHETIC-PASSWORD-CANARY"].exists)

    let command = app.staticTexts["device.field.command"]
    for _ in 0..<4 where !command.exists || !command.isHittable { app.swipeUp() }
    XCTAssertEqual(command.label, "ssh -p 2222 deploy@server.example.test")
    XCTAssertFalse(command.label.contains("CANARY"))
    XCTAssertTrue(app.buttons["device.share"].exists || app.links["device.share"].exists)
    attach(app, "device-detail")
    for _ in 0..<4 where !app.staticTexts["Web console"].exists { app.swipeUp() }
    XCTAssertTrue(app.staticTexts["Web console"].exists, "Services are listed")
    for _ in 0..<4 where !app.staticTexts["Restart service"].isHittable { app.swipeUp() }
    app.staticTexts["Restart service"].tap()
    XCTAssertTrue(app.staticTexts["••••••••••••"].waitForExistence(timeout: 5), "Documents start hidden")
    app.buttons["显示"].tap()
    XCTAssertTrue(app.staticTexts["systemctl restart web"].waitForExistence(timeout: 5))
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
