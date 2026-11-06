import XCTest

@testable import PasswordVault

@MainActor
final class QuickAccessTests: XCTestCase {
  func testWebsiteUsesFirstSafeURLAndDoesNotLaunchOtherSchemes() {
    var item = VaultItem.blank(type: "password", title: "Fixture")
    item.set("url", "https://example.test/login, https://second.test")
    XCTAssertEqual(QuickAccessSearch.website(item)?.absoluteString, "https://example.test/login")
    item.set("url", "file:///tmp/test")
    XCTAssertNil(QuickAccessSearch.website(item))
    item.set("url", "https://user:password@example.test")
    XCTAssertNil(QuickAccessSearch.website(item))
  }
  func testSearchDoesNotMatchSecretsAndExcludesTrash() {
    var first = VaultItem.blank(type: "password", title: "Example")
    first.username = "person@example.test"
    first.password = "SECRET_QUERY_CANARY"
    first.tags = ["Work"]
    var deleted = VaultItem.blank(type: "password", title: "Deleted example")
    deleted.isDeleted = true
    XCTAssertEqual(
      QuickAccessSearch.results([first, deleted], query: "EXAMPLE").map(\.id), [first.id])
    XCTAssertEqual(QuickAccessSearch.results([first], query: "work").count, 1)
    XCTAssertTrue(QuickAccessSearch.results([first], query: "SECRET_QUERY_CANARY").isEmpty)
  }

  func testLockClosesPanelAndLockedShortcutUsesMainWindow() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder)
    let controller = QuickAccessController()
    controller.attach(store)
    var openedMain = false
    controller.openMain = { openedMain = true }
    controller.toggle()
    XCTAssertTrue(openedMain)
    XCTAssertFalse(controller.isPresented)
    await store.authenticate(password: "Synthetic quick access fixture", create: true)
    controller.toggle()
    XCTAssertTrue(controller.isPresented)
    store.lock()
    XCTAssertFalse(controller.isPresented)
    await store.finishLock()
  }
}
