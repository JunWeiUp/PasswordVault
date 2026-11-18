import XCTest

@testable import PasswordVault

@MainActor
final class MobileBatchActionTests: XCTestCase {
  private func unlockedStore() async throws -> (MobileVaultStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MobileVaultStore(directory: directory)
    await store.start()
    await store.authenticate("Synthetic batch test 123!", create: true)
    XCTAssertTrue(store.unlocked)
    return (store, directory)
  }

  func testFavoriteMoveAndTrashOnlyChangeEditableSelectedEntries() async throws {
    let (store, directory) = try await unlockedStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let note = VaultItem.blank(type: "secureNote", title: "Note A")
    let other = VaultItem.blank(type: "secureNote", title: "Note B")
    let account = VaultItem.blank(type: "password", title: "Account")
    var trashed = VaultItem.blank(type: "secureNote", title: "Already in Trash")
    trashed.isDeleted = true
    for item in [note, other, account, trashed] { let ok = await store.save(item); XCTAssertTrue(ok) }

    let favorited = await store.favorite([note.id, account.id, trashed.id])
    XCTAssertEqual(favorited, 2, "Trash entries are skipped")
    func item(_ id: String) -> VaultItem? { store.items.first { $0.id == id } }
    XCTAssertTrue(item(note.id)?.isFavorite == true)
    XCTAssertTrue(item(account.id)?.isFavorite == true)
    XCTAssertFalse(item(other.id)?.isFavorite == true, "Unselected entries are unchanged")
    XCTAssertFalse(item(trashed.id)?.isFavorite == true)

    let moved = await store.move([note.id, account.id], to: "  Travel ")
    XCTAssertEqual(moved, 1, "Only notes move")
    XCTAssertEqual(item(note.id)?.category, "Travel")
    XCTAssertEqual(item(account.id)?.category, "")
    XCTAssertTrue(store.categories.contains("Travel"))
    let cleared = await store.move([note.id], to: "")
    XCTAssertEqual(cleared, 1)
    XCTAssertEqual(item(note.id)?.category, "")

    let trashedCount = await store.trash([note.id, account.id, "missing-id"])
    XCTAssertEqual(trashedCount, 2, "Unknown ids are ignored")
    XCTAssertTrue(item(note.id)?.isDeleted == true)
    XCTAssertFalse(item(note.id)?.string("deletedAt").isEmpty ?? true)
    XCTAssertTrue(item(account.id)?.isDeleted == true)
    XCTAssertFalse(item(other.id)?.isDeleted == true)
    await store.close()
  }

  func testBatchActionsDoNothingWhenLockedOrReadOnly() async throws {
    let (store, directory) = try await unlockedStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var shared = VaultItem.blank(type: "secureNote", title: "Shared")
    shared.set("sharedVaultId", "vault-without-membership")
    store.items = [shared]
    XCTAssertFalse(store.canEdit(shared))
    let skipped = await store.trash([shared.id])
    XCTAssertEqual(skipped, 0, "Entries this device may not edit are skipped")
    store.lock()
    let locked = await store.favorite([shared.id])
    XCTAssertEqual(locked, 0, "A locked store saves nothing")
    XCTAssertNil(store.error)
    await store.close()
  }
}
