import XCTest

/// Codes list, wallet grouping and wallet-secret confirmation on a fresh synthetic vault.
final class WalletCodesFlowTests: XCTestCase {
  func testLiveCodesWalletGroupingAndRecoveryPhraseConfirmation() {
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

    // Notes come first in the tab bar, matching the mobile baseline design.
    XCTAssertTrue(app.tabBars.buttons["全部笔记"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.tabBars.buttons.element(boundBy: 0).label, "全部笔记")

    // A code imported from a fictional setup link shows its live value in the list.
    app.tabBars.buttons["验证码"].tap()
    app.buttons["新建"].tap()
    app.buttons["新建条目"].tap()
    let link = app.textFields["otpauth://…"]
    XCTAssertTrue(link.waitForExistence(timeout: 5))
    link.tap()
    link.typeText("otpauth://totp/Example:alex@example.test?secret=JBSWY3DPEHPK3PXP&issuer=Example")
    app.buttons["导入设置链接"].tap()
    app.buttons["保存"].tap()
    let code = app.descendants(matching: .any)["code.row"].firstMatch
    XCTAssertTrue(code.waitForExistence(timeout: 10))
    XCTAssertTrue(waitFor(code, "value MATCHES '[0-9]{6}'"), "The list shows the current six-digit code")
    attach(app, "codes-list")

    // Wallets group cards, identities and crypto wallets.
    app.tabBars.buttons["钱包"].tap()
    XCTAssertTrue(app.segmentedControls["wallet-kind"].waitForExistence(timeout: 5))
    app.buttons["新建"].tap()
    XCTAssertTrue(app.buttons["银行卡"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["证件"].exists)
    app.buttons["加密货币钱包"].tap()
    let title = app.textFields["entry.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Example wallet")
    app.buttons["生成 ETH 钱包"].tap()
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts["Example wallet"].waitForExistence(timeout: 10))
    attach(app, "wallets-list")

    // The recovery phrase needs confirmation to show and cannot be copied.
    app.staticTexts["Example wallet"].firstMatch.tap()
    let note = app.staticTexts["助记词不支持复制，请抄写在离线介质上。"]
    for _ in 0..<6 where !note.isHittable { app.swipeUp() }
    XCTAssertTrue(note.isHittable)
    // The last "显示" button belongs to the recovery phrase.
    let shows = app.buttons.matching(NSPredicate(format: "label == '显示'"))
    shows.element(boundBy: shows.count - 1).tap()
    let reveal = app.buttons["确认周围无人，显示"]
    XCTAssertTrue(reveal.waitForExistence(timeout: 5))
    attach(app, "phrase-confirm")
    reveal.tap()
    XCTAssertTrue(app.buttons["隐藏"].waitForExistence(timeout: 5))
    attach(app, "phrase-shown")
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
