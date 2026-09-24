import UIKit
import XCTest

final class AutofillSystemTest: XCTestCase {
  func testEnableProviderInSystemSettings() throws {
    guard ProcessInfo.processInfo.environment["PV_SYSTEM_QA"] == "1" else {
      throw XCTSkip("Opt-in simulator system settings test")
    }
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    let provider = settings.switches.matching(
      NSPredicate(format: "label CONTAINS %@", "PasswordVault")
    ).firstMatch
    if !provider.waitForExistence(timeout: 2) {
      let general = settings.staticTexts["通用"]
      if general.waitForExistence(timeout: 2) { general.tap() }
      let autofill = settings.staticTexts["自动填充与密码"]
      for _ in 0..<8 where !autofill.isHittable { settings.swipeUp() }
      XCTAssertTrue(autofill.waitForExistence(timeout: 5))
      autofill.tap()
    }
    XCTAssertTrue(provider.waitForExistence(timeout: 5))
    if provider.value as? String == "0" { provider.switches.firstMatch.tap() }
    if settings.alerts.firstMatch.waitForExistence(timeout: 2) {
      let enable = settings.alerts.buttons["启用"]
      if enable.exists { enable.tap() }
    }
    XCTAssertEqual(provider.value as? String, "1")
  }
  func testSafariFill() throws {
    guard ProcessInfo.processInfo.environment["PV_SYSTEM_QA"] == "1" else {
      throw XCTSkip("Opt-in simulator Autofill test")
    }
    let app = XCUIApplication()
    app.launch()
    let password = app.secureTextFields["vault.password"]
    XCTAssertTrue(password.waitForExistence(timeout: 10))
    let creating = app.buttons["创建资料库"].exists
    password.tap()
    password.typeText("iOS Autofill QA 123!")
    if creating {
      let confirm = app.secureTextFields.element(boundBy: 1)
      confirm.tap()
      confirm.typeText("iOS Autofill QA 123!")
    }
    app.buttons["vault.unlock"].tap()
    XCTAssertTrue(app.buttons["新建"].waitForExistence(timeout: 10))
    app.buttons["新建"].tap()
    let title = app.textFields["entry.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Safari QA credentials")
    app.textFields["用户名"].tap()
    app.textFields["用户名"].typeText("autofill@example.test")
    app.secureTextFields["密码"].tap()
    app.secureTextFields["密码"].typeText("Fake Safari password 123!")
    app.textFields["网站"].tap()
    app.textFields["网站"].typeText("http://127.0.0.1:4387")
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts["Safari QA credentials"].firstMatch.waitForExistence(timeout: 5))
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    safari.activate()
    XCTAssertTrue(safari.secureTextFields.firstMatch.waitForExistence(timeout: 10))
    safari.secureTextFields.firstMatch.tap()
    safari.secureTextFields.firstMatch.typeText("x" + XCUIKeyboardKey.delete.rawValue)
    let passwords = safari.buttons["密码"]
    let visible = expectation(
      for: NSPredicate(format: "hittable == true"), evaluatedWith: passwords)
    wait(for: [visible], timeout: 5)
    passwords.tap()
    XCTAssertTrue(safari.buttons["PasswordVault"].waitForExistence(timeout: 5))
    safari.buttons["PasswordVault"].tap()
    let providerPassword = safari.secureTextFields["主密码 / Master password"]
    XCTAssertTrue(providerPassword.waitForExistence(timeout: 10))
    safari.buttons["取消 / Cancel"].tap()
    XCTAssertTrue(safari.buttons["模拟登录"].waitForExistence(timeout: 5))
    XCTAssertNotEqual(safari.textFields["账号"].value as? String, "autofill@example.test")
    safari.secureTextFields.firstMatch.tap()
    safari.secureTextFields.firstMatch.typeText("x" + XCUIKeyboardKey.delete.rawValue)
    let reopened = expectation(
      for: NSPredicate(format: "hittable == true"), evaluatedWith: passwords)
    wait(for: [reopened], timeout: 5)
    passwords.tap()
    safari.buttons["PasswordVault"].tap()
    XCTAssertTrue(providerPassword.waitForExistence(timeout: 10))
    providerPassword.tap()
    providerPassword.typeText("iOS Autofill QA 123!")
    safari.buttons["解锁 / Unlock"].tap()
    let candidate = safari.staticTexts["Safari QA credentials"].firstMatch
    XCTAssertTrue(candidate.waitForExistence(timeout: 10))
    candidate.tap()
    let filled = expectation(
      for: NSPredicate(format: "value == %@", "autofill@example.test"),
      evaluatedWith: safari.textFields["账号"])
    wait(for: [filled], timeout: 10)
    XCTAssertTrue(safari.buttons["模拟登录"].exists)
    XCTAssertFalse((safari.secureTextFields.firstMatch.value as? String ?? "").isEmpty)
    XCTAssertNotEqual(safari.secureTextFields.firstMatch.value as? String, "至少 8 位测试密码")
    let attachment = XCTAttachment(string: safari.debugDescription)
    attachment.lifetime = .keepAlways
    add(attachment)
    let shot = XCTAttachment(screenshot: safari.screenshot())
    shot.lifetime = .keepAlways
    add(shot)
  }

}
