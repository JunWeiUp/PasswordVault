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
    XCTAssertTrue(app.navigationBars["添加验证码"].waitForExistence(timeout: 5))
    let link = app.textFields["otpauth://…"]
    XCTAssertTrue(link.waitForExistence(timeout: 5))
    link.tap()
    link.typeText("otpauth://totp/Example:alex@example.test?secret=JBSWY3DPEHPK3PXP&issuer=Example")
    app.buttons["导入"].tap()
    let code = app.descendants(matching: .any)["code.row"].firstMatch
    XCTAssertTrue(code.waitForExistence(timeout: 10))
    XCTAssertTrue(waitFor(code, "value MATCHES '[0-9]{6}'"), "The list shows the current six-digit code")
    attach(app, "codes-list")

    // Wallets group cards, identities and crypto wallets.
    app.tabBars.buttons["钱包"].tap()
    XCTAssertTrue(app.segmentedControls["wallet-kind"].waitForExistence(timeout: 5))
    app.buttons["新建"].tap()
    XCTAssertTrue(app.buttons["银行卡"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["身份证件"].exists)
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

  /// Identity documents: created in the editor, shown with labels, number concealed until revealed.
  func testIdentityDocumentCreateRevealAndEdit() {
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

    XCTAssertTrue(app.tabBars.buttons["钱包"].waitForExistence(timeout: 10))
    app.tabBars.buttons["钱包"].tap()
    app.buttons["新建"].tap()
    XCTAssertTrue(app.buttons["身份证件"].waitForExistence(timeout: 5))
    app.buttons["身份证件"].tap()
    let title = app.textFields["entry.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Passport fixture")
    let type = app.textFields["document.type"]
    for _ in 0..<6 where !type.isHittable { app.swipeUp() }
    type.tap()
    type.typeText("Passport")
    let number = app.textFields["证件号码"]
    number.tap()
    number.typeText("E7654321")
    let expiry = app.buttons["添加有效期至"]
    for _ in 0..<3 where !expiry.isHittable { app.swipeUp() }
    expiry.tap()
    attach(app, "identity-editor")
    XCTAssertTrue(waitFor(app.buttons["保存"], "isEnabled == true"))
    app.buttons["保存"].tap()

    let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Passport fixture'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.staticTexts["证件信息"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["证件类型"].exists)
    XCTAssertTrue(app.staticTexts["Passport"].exists)
    XCTAssertTrue(app.staticTexts["有效期至"].exists)
    XCTAssertFalse(app.staticTexts["E7654321"].exists, "The number is concealed")
    XCTAssertFalse(app.staticTexts["document.number"].exists, "Field ids are never shown")
    let copy = app.buttons.matching(NSPredicate(format: "label == '复制'")).element(boundBy: 1)
    XCTAssertFalse(copy.isEnabled, "The number copies only after it is revealed")
    attach(app, "identity-concealed")
    app.buttons.matching(NSPredicate(format: "label == '显示'")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["E7654321"].waitForExistence(timeout: 5))
    XCTAssertTrue(copy.isEnabled)
    copy.tap()
    attach(app, "identity-revealed")

    // Editing keeps the document fields and updates the value in place.
    app.buttons["编辑"].tap()
    let typeEdit = app.textFields["document.type"]
    for _ in 0..<6 where !typeEdit.isHittable { app.swipeUp() }
    XCTAssertEqual(typeEdit.value as? String, "Passport")
    typeEdit.tap()
    typeEdit.typeText(" card")
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts["Passport card"].waitForExistence(timeout: 10))
  }

  /// Add code sheet: manual key entry with period, a rejected key, then the saved code.
  func testAddCodeManuallyWithPeriod() {
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

    XCTAssertTrue(app.tabBars.buttons["验证码"].waitForExistence(timeout: 10))
    app.tabBars.buttons["验证码"].tap()
    app.buttons["新建"].tap()
    XCTAssertTrue(app.navigationBars["添加验证码"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["从图片识别二维码"].exists)
    attach(app, "add-code-sheet")
    app.buttons["code.manual"].tap()
    let issuer = app.textFields["code.issuer"]
    XCTAssertTrue(issuer.waitForExistence(timeout: 5))
    issuer.tap()
    issuer.typeText("GitLab")
    let secret = app.textFields["code.secret"]
    secret.tap()
    secret.typeText("not base32!")
    let period = app.textFields["code.period"]
    // The field is right-aligned; tapping its trailing edge puts the cursor after "30".
    period.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    period.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "60")
    XCTAssertEqual(period.value as? String, "60")
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '6 位 · SHA1'")).firstMatch.exists
      || app.staticTexts["位数 · 算法, 6 位 · SHA1"].exists, "Digits are fixed by the core")
    app.buttons["code.add"].tap()
    XCTAssertTrue(app.staticTexts["设置密钥无效，请检查后重试。"].waitForExistence(timeout: 10))
    secret.tap()
    for _ in 0..<12 { secret.typeText(XCUIKeyboardKey.delete.rawValue) }
    secret.typeText("JBSW Y3DP EHPK 3PXP")
    app.buttons["code.add"].tap()

    let code = app.descendants(matching: .any)["code.row"].firstMatch
    XCTAssertTrue(code.waitForExistence(timeout: 10))
    XCTAssertEqual(code.label, "GitLab")
    app.buttons["查看详情"].firstMatch.tap()
    let config = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'SHA1 · 6 位 · 60 秒'")).firstMatch
    XCTAssertTrue(config.waitForExistence(timeout: 5))
    let none = app.staticTexts["code.linked.none"]
    for _ in 0..<4 where !none.isHittable { app.swipeUp() }
    XCTAssertTrue(none.exists, "No account shares this key")
    attach(app, "code-detail-linked")
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
