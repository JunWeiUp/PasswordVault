import XCTest

/// Settings follows the mobile baseline design: library views, grouped pages, About.
final class SettingsFlowTests: XCTestCase {
  func testLibraryViewsAndGroupedSettingsPages() {
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

    // A favorite account appears in All items and Favorites.
    XCTAssertTrue(app.tabBars.buttons["密码"].waitForExistence(timeout: 10))
    app.tabBars.buttons["密码"].tap()
    app.buttons["新建"].tap()
    app.buttons["新建条目"].tap()
    let title = app.textFields["entry.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Library fixture")
    XCTAssertTrue(waitFor(app.buttons["保存"], "isEnabled == true"))
    app.buttons["保存"].tap()
    let row = app.staticTexts["Library fixture"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    // Favorite it from the detail page's star button, then go back.
    app.buttons["Library fixture"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars.buttons["收藏"].waitForExistence(timeout: 5))
    app.navigationBars.buttons["收藏"].tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()

    app.tabBars.buttons["设置"].tap()
    for label in ["全部项目", "个人收藏", "回收站", "笔记分类", "通用", "安全", "自动填充与通行密钥", "同步与设备", "备份与导入"] {
      XCTAssertTrue(app.staticTexts[label].firstMatch.waitForExistence(timeout: 5), label)
    }
    app.staticTexts["个人收藏"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Library fixture"].firstMatch.waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.staticTexts["全部项目"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Library fixture"].firstMatch.waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()

    app.staticTexts["自动填充与通行密钥"].firstMatch.tap()
    XCTAssertTrue(app.buttons["打开系统设置"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()

    for _ in 0..<4 where !app.staticTexts["关于"].firstMatch.isHittable { app.swipeUp() }
    app.staticTexts["关于"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["版本"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '尚未完成独立安全审计'")).firstMatch.exists)
  }

  private func waitFor(_ element: XCUIElement, _ predicate: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }
}
