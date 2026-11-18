import XCTest

/// Account rows copy the password in one tap; code details show the next code.
final class ListsCodesFlowTests: XCTestCase {
  func testCopyPasswordFromRowAndNextCode() {
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

    XCTAssertTrue(app.tabBars.buttons["密码"].waitForExistence(timeout: 10))
    app.tabBars.buttons["密码"].tap()
    app.buttons["新建"].tap()
    app.buttons["新建条目"].tap()
    let title = app.textFields["entry.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Copy fixture")
    let secret = app.secureTextFields["密码"].firstMatch
    secret.tap()
    secret.typeText("Fixture-pass-1")
    XCTAssertTrue(waitFor(app.buttons["保存"], "isEnabled == true"))
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons["Copy fixture"].firstMatch.waitForExistence(timeout: 10))

    let copy = app.buttons["row.copyPassword"].firstMatch
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    XCTAssertEqual(copy.label, "复制密码")
    XCTAssertTrue(copy.isEnabled)
    attach(app, "accounts-copy")
    copy.tap()
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '已复制'")).firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Fixture-pass-1"].exists, "The row never shows the password")

    app.tabBars.buttons["验证码"].tap()
    app.buttons["新建"].tap()
    XCTAssertTrue(app.navigationBars["添加验证码"].waitForExistence(timeout: 5))
    let link = app.textFields["otpauth://…"]
    XCTAssertTrue(link.waitForExistence(timeout: 5))
    link.tap()
    link.typeText("otpauth://totp/Example:alex@example.test?secret=JBSWY3DPEHPK3PXP&issuer=Example")
    app.buttons["导入"].tap()
    let details = app.buttons["查看详情"].firstMatch
    XCTAssertTrue(details.waitForExistence(timeout: 10))
    details.tap()
    let next = app.staticTexts["code.next"]
    XCTAssertTrue(next.waitForExistence(timeout: 10))
    XCTAssertTrue(waitFor(next, "label MATCHES '下一个 [0-9]{3} [0-9]{3} · [0-9]+ 秒后生效'"), next.label)
    attach(app, "code-next")
  }

  private func waitFor(_ element: XCUIElement, _ predicate: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
