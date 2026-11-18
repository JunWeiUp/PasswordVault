import XCTest

@testable import PasswordVault

@MainActor
final class MobileTrashTests: XCTestCase {
  private func item(_ id: String, deleted: Bool, shared: String = "") -> VaultItem {
    var value = VaultItem.blank(type: "secureNote", title: id)
    value.fields["id"] = .string(id)
    value.isDeleted = deleted
    if !shared.isEmpty { value.set("sharedVaultId", shared) }
    return value
  }

  func testEmptyTrashKeepsSharedAndReadOnlyEntries() {
    let items = [
      item("own", deleted: true), item("live", deleted: false),
      item("shared", deleted: true, shared: "vault-1"), item("readOnly", deleted: true),
    ]
    let plan = TrashPlan(items: items, canEdit: { $0.id != "readOnly" })
    XCTAssertEqual(plan.removable.map(\.id), ["own"])
    XCTAssertEqual(plan.kept, 2, "Shared and read-only entries stay in Trash")
  }

  func testUndoRestoresLatestCopyAndEmptyTrashDeletesPermanently() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MobileVaultStore(directory: directory)
    await store.start()
    await store.authenticate("trash test password 123!", create: true)
    let first = VaultItem.blank(type: "secureNote", title: "First")
    let second = VaultItem.blank(type: "secureNote", title: "Second")
    let saved1 = await store.save(first)
    let saved2 = await store.save(second)
    XCTAssertTrue(saved1 && saved2)

    let moved = await store.trash(first)
    XCTAssertTrue(moved)
    XCTAssertEqual(store.undoTrashID, first.id)
    XCTAssertTrue(store.items.first { $0.id == first.id }?.isDeleted == true)
    await store.undoTrash()
    XCTAssertNil(store.undoTrashID)
    XCTAssertTrue(store.items.first { $0.id == first.id }?.isDeleted == false, "Undo restores the entry")

    _ = await store.trash(second)
    let removed = await store.emptyTrash()
    XCTAssertEqual(removed, 1)
    XCTAssertNil(store.items.first { $0.id == second.id }, "Empty Trash deletes permanently")
    XCTAssertNotNil(store.items.first { $0.id == first.id })
    await store.close()
    try? FileManager.default.removeItem(at: directory)
  }
}
