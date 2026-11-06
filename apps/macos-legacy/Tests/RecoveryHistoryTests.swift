import XCTest

@testable import PasswordVault

@MainActor
final class RecoveryHistoryTests: XCTestCase {
  func testRecoveryExportFlushesPendingNoteAndRestoresIntoNewVault() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: target)
    }
    let store = AppStore(directory: source)
    await store.authenticate(password: "Synthetic recovery fixture", create: true)
    var item = VaultItem.blank(type: "secureNote", title: "Recovery fixture")
    let saved = await store.save(item)
    XCTAssertTrue(saved)
    let generated = try await store.perform(["op": .string("recovery-generate")])
    let key = try XCTUnwrap(generated.object["key"]?.string)
    _ = try await store.perform([
      "op": .string("recovery-enable"), "key": .string(key),
      "currentPassword": .string("Synthetic recovery fixture"),
    ])
    item.note = "Latest pending draft"
    store.editNote(item)
    let archive = try await store.perform(["op": .string("recovery-export"), "key": .string(key)])
    let restored = AppStore(directory: target)
    await restored.recover(
      key: key, newPassword: "New fixture password", archive: archive.object["content"]?.string)
    XCTAssertTrue(restored.unlocked)
    XCTAssertEqual(restored.items.first?.note, "Latest pending draft")
    store.lock()
    await store.finishLock()
    restored.lock()
    await restored.finishLock()
  }

  func testHistoryRestorePreservesCurrentDraftAsVersion() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder)
    await store.authenticate(password: "Synthetic history fixture", create: true)
    var item = VaultItem.blank(type: "secureNote", title: "History fixture")
    item.note = "Original"
    let saved = await store.save(item)
    XCTAssertTrue(saved)
    _ = try await store.perform(["op": .string("history-enable")])
    let rows = try await store.perform(["op": .string("history-list"), "id": .string(item.id)])
    let revision = try XCTUnwrap(rows.object["revisions"]?.array.first?.object["id"]?.string)
    item.note = "Pending before restore"
    store.editNote(item)
    _ = try await store.perform([
      "op": .string("history-restore"), "id": .string(item.id), "revisionId": .string(revision),
      "time": .string(ISO8601DateFormatter().string(from: Date())),
    ])
    await store.refresh()
    XCTAssertEqual(store.items.first?.note, "Original")
    let history = try await store.perform(["op": .string("history-list"), "id": .string(item.id)])
    XCTAssertTrue(
      history.object["revisions"]?.array.contains(where: {
        $0.object["item"]?.object["note"]?.string == "Pending before restore"
      }) ?? false)
    store.lock()
    await store.finishLock()
  }

  func testRecoveryResetDoesNotAcceptWrongKey() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder)
    await store.authenticate(password: "Synthetic recovery fixture", create: true)
    let generated = try await store.perform(["op": .string("recovery-generate")])
    let key = try XCTUnwrap(generated.object["key"]?.string)
    _ = try await store.perform([
      "op": .string("recovery-enable"), "key": .string(key),
      "currentPassword": .string("Synthetic recovery fixture"),
    ])
    store.lock()
    await store.finishLock()
    await store.recover(key: "incorrect", newPassword: "replacement password", archive: nil)
    XCTAssertFalse(store.unlocked)
    XCTAssertNotNil(store.authenticationError)
    await store.recover(key: key, newPassword: "replacement password", archive: nil)
    XCTAssertTrue(store.unlocked)
    store.lock()
    await store.finishLock()
    await store.authenticate(password: "replacement password", create: false)
    XCTAssertTrue(store.unlocked)
    store.lock()
    await store.finishLock()
  }
}
