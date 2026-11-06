import XCTest

@testable import PasswordVault

@MainActor
final class MobileRecoveryTests: XCTestCase {
  func testRecoveryAndHistoryRoundTripWithOneCharacterNewPassword() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MobileVaultStore(directory: source)
    let restored = MobileVaultStore(directory: target)
    await store.authenticate("original", create: true)
    var item = VaultItem.blank(type: "secureNote", title: "Fixture")
    item.note = "Original contents"
    let saved = await store.save(item)
    XCTAssertTrue(saved)
    _ = try await store.perform(["op": .string("history-enable")])
    item.note = "Edited contents"
    let edited = await store.save(item)
    XCTAssertTrue(edited)
    let key = try await store.perform(["op": .string("recovery-generate")]).object["key"]!.string
    _ = try await store.perform([
      "op": .string("recovery-enable"), "key": .string(key), "currentPassword": .string("original"),
    ])
    let archive = try await store.perform(["op": .string("recovery-export"), "key": .string(key)])
      .object["content"]!.string
    await restored.recover(key: key, newPassword: "x", archive: archive)
    XCTAssertTrue(restored.unlocked)
    XCTAssertEqual(restored.items.first?.note, "Edited contents")
    let rows = try await restored.perform(["op": .string("history-list"), "id": .string(item.id)])
      .object["revisions"]!.array
    XCTAssertEqual(rows.count, 2)
    _ = try await restored.perform([
      "op": .string("history-restore"), "id": .string(item.id),
      "revisionId": rows.last!.object["id"]!,
      "time": .string(ISO8601DateFormatter().string(from: Date())),
    ])
    try await restored.refresh()
    XCTAssertEqual(restored.items.first?.note, "Original contents")
    _ = try await restored.perform([
      "op": .string("export"), "password": .string("long backup fixture"),
    ])
    await store.close()
    await restored.close()
    try FileManager.default.removeItem(at: source)
    try FileManager.default.removeItem(at: target)
  }
  func testDraftBlocksRecoveryExportAndWrongKeyKeepsLocked() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MobileVaultStore(directory: directory)
    await store.authenticate("original", create: true)
    let key = try await store.perform(["op": .string("recovery-generate")]).object["key"]!.string
    _ = try await store.perform([
      "op": .string("recovery-enable"), "key": .string(key), "currentPassword": .string("original"),
    ])
    store.pendingDraft = VaultItem.blank(type: "secureNote", title: "Unfinished")
    do {
      _ = try await store.perform(["op": .string("recovery-export"), "key": .string(key)])
      XCTFail("Pending draft must not be omitted silently")
    } catch {}
    store.pendingDraft = nil
    store.lock()
    await store.recover(key: "bad", newPassword: "x")
    XCTAssertFalse(store.unlocked)
    await store.recover(key: key, newPassword: "x")
    XCTAssertTrue(store.unlocked)
    await store.close()
    try FileManager.default.removeItem(at: directory)
  }
}
