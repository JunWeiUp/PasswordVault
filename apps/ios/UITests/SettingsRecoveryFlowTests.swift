import XCTest

/// Settings › General start tab and clipboard duration, recovery-key spot check, password health cards.
final class SettingsRecoveryFlowTests: XCTestCase {
  private func unlock(_ app: XCUIApplication, create: Bool) {
    let password = app.secureTextFields["vault.password"]
    XCTAssertTrue(password.waitForExistence(timeout: 10))
    password.tap()
    password.typeText("1")
    if create {
      let confirm = app.secureTextFields.element(boundBy: 1)
      confirm.tap()
      confirm.typeText("1")
    }
    app.buttons["vault.unlock"].tap()
  }

  /// Menu pickers expose their title and current value in one button label.
  private func picker(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    let element = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 5), title)
    return element
  }

  /// Picks a menu option, skipping a tab-bar button with the same label.
  private func choose(_ app: XCUIApplication, _ label: String) {
    let tabBar = app.tabBars.firstMatch.frame
    let options = app.buttons.matching(NSPredicate(format: "label == %@", label))
    XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 5))
    let option = options.allElementsBoundByIndex.first { !tabBar.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    XCTAssertNotNil(option, label)
    option?.tap()
  }

  func testStartTabAndClipboardDuration() {
    let vault = UUID().uuidString
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-vault", vault]
    app.launch()
    unlock(app, create: true)
    XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 10))
    app.tabBars.buttons["设置"].tap()
    app.staticTexts["通用"].firstMatch.tap()
    picker(app, "打开时显示").tap()
    choose(app, "验证码")
    picker(app, "自动清除剪贴板").tap()
    choose(app, "15 秒")
    attach(app, "general-settings")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.staticTexts["密码生成器"].firstMatch.tap()
    XCTAssertTrue(app.buttons["复制"].waitForExistence(timeout: 5))
    XCTAssertTrue(waitFor(app.buttons["复制"], "isEnabled == true"))
    app.buttons["复制"].tap()
    XCTAssertTrue(app.staticTexts["已复制，15 秒后清除"].waitForExistence(timeout: 5))

    app.terminate()
    app.launch()
    unlock(app, create: false)
    let codes = app.tabBars.buttons["验证码"]
    XCTAssertTrue(codes.waitForExistence(timeout: 10))
    XCTAssertTrue(waitFor(codes, "selected == true"), "Opens to the chosen tab")
    XCTAssertTrue(app.navigationBars["验证码"].exists)
    // Restore the default for other tests on this simulator.
    app.tabBars.buttons["设置"].tap()
    app.staticTexts["通用"].firstMatch.tap()
    picker(app, "打开时显示").tap()
    choose(app, "全部笔记")
    picker(app, "自动清除剪贴板").tap()
    choose(app, "30 秒")
  }

  func testRecoverySpotCheckAndHealthCards() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-vault", UUID().uuidString]
    app.launch()
    unlock(app, create: true)
    XCTAssertTrue(app.tabBars.buttons["密码"].waitForExistence(timeout: 10))
    app.tabBars.buttons["密码"].tap()
    for name in ["Health one", "Health two"] {
      app.buttons["新建"].tap()
      app.buttons["新建条目"].tap()
      let title = app.textFields["entry.title"]
      XCTAssertTrue(title.waitForExistence(timeout: 5))
      title.tap()
      title.typeText(name)
      let secret = app.secureTextFields["密码"].firstMatch
      secret.tap()
      secret.typeText("short1")
      XCTAssertTrue(waitFor(app.buttons["保存"], "isEnabled == true"))
      app.buttons["保存"].tap()
      XCTAssertTrue(app.buttons[name].firstMatch.waitForExistence(timeout: 10))
    }

    app.tabBars.buttons["设置"].tap()
    app.staticTexts["密码健康"].firstMatch.tap()
    let weak = app.buttons["health.weak"]
    XCTAssertTrue(weak.waitForExistence(timeout: 5))
    XCTAssertTrue(waitFor(weak, "label CONTAINS '2'"), weak.label)
    XCTAssertTrue(app.buttons["health.reused"].label.contains("2"))
    XCTAssertTrue(app.buttons["health.expired"].label.contains("0"))
    XCTAssertTrue(app.buttons["health.breach"].exists)
    app.buttons["health.expired"].tap()
    XCTAssertTrue(app.staticTexts["未发现风险条目"].waitForExistence(timeout: 5), "Filtering to expired shows none")
    app.buttons["health.weak"].tap()
    XCTAssertTrue(app.staticTexts["Health one"].waitForExistence(timeout: 5))
    attach(app, "password-health")
    app.navigationBars.buttons.element(boundBy: 0).tap()

    app.staticTexts["安全"].firstMatch.tap()
    app.staticTexts["应急恢复"].firstMatch.tap()
    let current = app.secureTextFields["当前主密码"]
    XCTAssertTrue(current.waitForExistence(timeout: 5))
    current.tap()
    current.typeText("1")
    app.buttons["生成 / 更换密钥"].tap()
    XCTAssertTrue(app.staticTexts["recovery.group.0"].waitForExistence(timeout: 10))
    var groups: [String] = []
    while app.staticTexts["recovery.group.\(groups.count)"].exists {
      groups.append(app.staticTexts["recovery.group.\(groups.count)"].label)
    }
    XCTAssertEqual(groups.count, 9)
    let enable = app.buttons["确认启用"]
    let fields = [app.secureTextFields["recovery.check.0"], app.secureTextFields["recovery.check.1"]]
    for _ in 0..<4 where !enable.isHittable { app.swipeUp() }
    let saved = app.switches["已在密码库之外保存密钥"]
    saved.switches.firstMatch.tap()
    // A wrong group keeps the key disabled.
    let indices = fields.map { field -> Int in
      let digits = field.placeholderValue?.filter(\.isNumber) ?? ""
      return (Int(digits) ?? 1) - 1
    }
    fields[0].tap()
    fields[0].typeText("00000000")
    fields[1].tap()
    fields[1].typeText(groups[indices[1]])
    XCTAssertFalse(enable.isEnabled, "A wrong group cannot enable the key")
    fields[0].tap()
    fields[0].press(forDuration: 1.0)
    if app.menuItems["全选"].waitForExistence(timeout: 2) { app.menuItems["全选"].tap() }
    fields[0].typeText(XCUIKeyboardKey.delete.rawValue)
    fields[0].typeText(groups[indices[0]])
    attach(app, "recovery-spot-check")
    XCTAssertTrue(waitFor(enable, "isEnabled == true"))
    enable.tap()
    XCTAssertTrue(app.staticTexts["已启用，请导出完整应急备份。"].waitForExistence(timeout: 10))
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
