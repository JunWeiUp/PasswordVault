import XCTest

/// Opt-in: use only a disposable PasswordVault Passkey QA simulator and the local TLS fixture.
final class PasskeySystemTests: XCTestCase {
  func testSafariRegistrationAndAssertion() throws {
    guard ProcessInfo.processInfo.environment["PV_PASSKEY_QA"] == "1" else {
      throw XCTSkip("Requires dedicated simulator, trusted local TLS fixture and synthetic vault")
    }
    #if !targetEnvironment(simulator)
    throw XCTSkip("Synthetic provider acceptance is simulator-only")
    #endif
    let app = XCUIApplication()
    app.launch()
    let secret = "Passkey QA synthetic only!"
    let input = app.secureTextFields["vault.password"]
    XCTAssertTrue(input.waitForExistence(timeout: 15))
    input.tap(); input.typeText(secret)
    if app.buttons["创建资料库"].exists {
      let confirm = app.secureTextFields.element(boundBy: 1)
      confirm.tap(); confirm.typeText(secret)
    }
    app.buttons["vault.unlock"].tap()
    XCTAssertTrue(app.buttons["新建"].waitForExistence(timeout: 15))
    app.terminate()

    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    let general = settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["通用", "General"])).firstMatch
    XCTAssertTrue(general.waitForExistence(timeout: 10)); general.tap()
    let autofill = settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["自动填充与密码", "AutoFill & Passwords"])).firstMatch
    for _ in 0..<8 where !autofill.isHittable { settings.swipeUp() }
    XCTAssertTrue(autofill.waitForExistence(timeout: 5)); autofill.tap()
    let provider = settings.switches.matching(NSPredicate(format: "label CONTAINS %@", "PasswordVault")).firstMatch
    XCTAssertTrue(provider.waitForExistence(timeout: 5))
    if provider.value as? String == "0" { if provider.switches.firstMatch.exists { provider.switches.firstMatch.tap() } else { provider.tap() } }
    XCTAssertEqual(provider.value as? String, "1")
    if settings.alerts.firstMatch.waitForExistence(timeout: 2) {
      let enable = settings.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["启用", "Enable"])).firstMatch
      if enable.exists { enable.tap() }
    }
    let builtIn = settings.switches["AutoFillFromPasswordsToggle"]
    if builtIn.exists && builtIn.value as? String == "1" { if builtIn.switches.firstMatch.exists { builtIn.switches.firstMatch.tap() } else { builtIn.tap() } }
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    safari.activate()
    let create = safari.buttons["Create synthetic passkey"]
    XCTAssertTrue(create.waitForExistence(timeout: 15)); create.tap()
    let choose = safari.buttons.matching(NSPredicate(format: "label CONTAINS %@", "PasswordVault")).firstMatch
    if choose.waitForExistence(timeout: 4) { choose.tap() }
    let authentication = XCUIApplication(bundleIdentifier: "com.apple.AuthenticationServicesUI")
    let addPasskey = authentication.buttons.matching(NSPredicate(format: "label IN %@", ["添加通行密钥", "Add Passkey", "继续", "Continue"])).firstMatch
    if addPasskey.waitForExistence(timeout: 2) { addPasskey.tap() }
    else {
      // iOS 26 Simulator's system credential sheet omits actionable AX nodes.
      // This opt-in fixture is restricted to its dedicated iPhone 17 Pro simulator.
      safari.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)).tap()
    }
    let providerUI = XCUIApplication(bundleIdentifier: "com.securepass.vault.ios.nativepreview.autofill")
    let approval = providerUI.secureTextFields.firstMatch
    if !approval.waitForExistence(timeout: 8) {
      let attachment = XCTAttachment(string: safari.debugDescription); attachment.lifetime = .keepAlways; add(attachment)
      XCTFail("Passkey provider confirmation did not appear"); return
    }
    approval.tap(); approval.typeText(secret)
    providerUI.buttons["解锁 / Unlock"].tap()
    let backup = providerUI.secureTextFields["独立备份口令（至少 10 字符） / Backup passphrase"]
    XCTAssertTrue(backup.waitForExistence(timeout: 10)); backup.tap(); backup.typeText("Separate QA backup phrase!")
    let backupConfirm = providerUI.secureTextFields["确认备份口令 / Confirm backup passphrase"]
    backupConfirm.tap(); backupConfirm.typeText("Separate QA backup phrase!")
    let register = providerUI.buttons["创建通行密钥 / Create passkey"]
    XCTAssertTrue(register.waitForExistence(timeout: 10)); register.tap()
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentManagerUICore.Service")
    let save = files.buttons.matching(NSPredicate(format: "label IN %@", ["存储", "保存", "Save"])).firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
    XCTAssertTrue(safari.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Registration PASS")).firstMatch.waitForExistence(timeout: 15))
    safari.buttons["Use synthetic passkey"].tap()
    let usePasskey = authentication.buttons.matching(NSPredicate(format: "label IN %@", ["使用通行密钥", "Use Passkey", "继续", "Continue"])).firstMatch
    if usePasskey.waitForExistence(timeout: 2) { usePasskey.tap() }
    else { safari.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)).tap() }
    let account = providerUI.buttons.matching(NSPredicate(format: "label CONTAINS %@", "synthetic@example.test")).firstMatch
    if account.waitForExistence(timeout: 4) { account.tap() }
    XCTAssertTrue(approval.waitForExistence(timeout: 10)); approval.tap(); approval.typeText(secret)
    providerUI.buttons["解锁 / Unlock"].tap()
    XCTAssertTrue(account.waitForExistence(timeout: 10)); account.tap()
    XCTAssertTrue(safari.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Assertion PASS")).firstMatch.waitForExistence(timeout: 15))
    let screenshot = XCTAttachment(screenshot: safari.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
  }
}
