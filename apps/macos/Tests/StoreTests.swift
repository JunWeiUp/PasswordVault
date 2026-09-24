import XCTest

@testable import PasswordVault

@MainActor
final class StoreTests: XCTestCase {
  func testWindowRestartKeepsUnlockedStoreAndExistingBridgeSocket() async throws {
    let folder = URL(fileURLWithPath: "/tmp/pv-window-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder)
    await store.start()
    await store.authenticate(password: "Synthetic window fixture 42!", create: true)
    let path = folder.appendingPathComponent("bridge.sock").path
    let before = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
    XCTAssertNotNil(before)
    await store.start()
    let after = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
    XCTAssertEqual(before, after, "Reopening must not replace/unlink the browser bridge socket")
    XCTAssertTrue(store.ready)
    XCTAssertTrue(store.unlocked)
    store.lock()
    await store.finishLock()
  }

  func testLatestNoteEditSurvivesFlushLockAndReopen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder)
    await store.authenticate(password: "Synthetic store fixture 24!", create: true)
    XCTAssertTrue(store.unlocked)
    var item = VaultItem.blank(type: "secureNote", title: "Synthetic note")
    let saved = await store.save(item)
    XCTAssertTrue(saved)
    item.note = "First draft"
    store.editNote(item)
    let flushing = Task { await store.flushChanges() }
    item.note = "Latest draft must survive"
    store.editNote(item)
    await flushing.value
    store.lock()
    XCTAssertFalse(store.unlocked)
    XCTAssertTrue(store.items.isEmpty)
    await store.finishLock()
    await store.authenticate(password: "Synthetic store fixture 24!", create: false)
    XCTAssertEqual(store.items.first?.note, "Latest draft must survive")
    store.lock()
    await store.finishLock()
  }
  func testBiometricAccountsAreScopedToEachVaultDirectory() {
    let root = FileManager.default.temporaryDirectory
    XCTAssertNotEqual(
      BiometricStore.account(for: root.appendingPathComponent("first")),
      BiometricStore.account(for: root.appendingPathComponent("second")))
  }

  func testEmptyCategoryPersistsAndRemovalFlushesDraftWithoutDeletingNote() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder)
    await store.authenticate(password: "Synthetic category fixture 24!", create: true)
    try await store.addCategory(" 新分类 ")
    XCTAssertEqual(store.category, "新分类")
    XCTAssertTrue(store.categories.contains("新分类"))
    XCTAssertTrue(store.visibleItems.isEmpty)
    store.lock()
    await store.finishLock()
    await store.authenticate(password: "Synthetic category fixture 24!", create: false)
    XCTAssertTrue(store.categories.contains("新分类"))
    store.navigate(.notes, category: "新分类")
    await store.newItem()
    var note = try XCTUnwrap(store.selected)
    XCTAssertEqual(note.category, "新分类")
    note.note = "Latest unsaved text must survive category removal"
    store.editNote(note)
    try await store.removeCategory("新分类")
    XCTAssertNil(store.category)
    XCTAssertFalse(store.categories.contains("新分类"))
    XCTAssertEqual(store.items.count, 1)
    XCTAssertEqual(store.items[0].note, note.note)
    XCTAssertEqual(store.items[0].category, "")
    store.lock()
    await store.finishLock()
    await store.authenticate(password: "Synthetic category fixture 24!", create: false)
    XCTAssertFalse(store.categories.contains("新分类"))
    XCTAssertEqual(store.items[0].note, note.note)
    store.lock()
    await store.finishLock()
  }
}
