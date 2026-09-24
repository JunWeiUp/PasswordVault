import XCTest

@testable import PasswordVault

final class MobileCoreTests: XCTestCase {
  private static func files(_ directory: URL) -> [URL] {
    FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?
      .allObjects as? [URL] ?? []
  }
  func testEncryptedLifecycleAndFailedImport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let core = try MobileCore(directory: directory)
    _ = try await core.call([
      "op": .string("create"), "password": .string("Synthetic mobile test 123!"),
    ])
    var note = VaultItem.blank(type: "secureNote", title: "MOBILE_TITLE_CANARY_391")
    note.note = "MOBILE_NOTE_CANARY_753"
    _ = try await core.call(["op": .string("save"), "item": try .from(note)])
    let exported = try await core.call([
      "op": .string("export"), "password": .string("Independent backup 123!"),
    ]).object["content"]!.string
    do {
      _ = try await core.call([
        "op": .string("import"), "content": .string(exported), "password": .string("wrong"),
        "kind": .string("json"),
      ])
      XCTFail("Wrong password accepted")
    } catch {}
    let document = try await core.document()
    XCTAssertEqual(document.items.count, 1)
    XCTAssertEqual(document.items.first?.note, note.note)
    for url in Self.files(directory) {
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let data = try Data(contentsOf: url)
        XCTAssertNil(data.range(of: Data(note.title.utf8)))
        XCTAssertNil(data.range(of: Data(note.note.utf8)))
      }
    }
    await core.close()
    let reopened = try MobileCore(directory: directory)
    do {
      _ = try await reopened.document()
      XCTFail("Locked read accepted")
    } catch {}
    _ = try await reopened.call([
      "op": .string("unlock"), "password": .string("Synthetic mobile test 123!"),
    ])
    let restored = try await reopened.document()
    XCTAssertEqual(restored.items.first?.id, note.id)
    await reopened.close()
  }
}

@MainActor
final class MobileDraftTests: XCTestCase {
  func testFailedDraftWriteKeepsEncryptedRecoveryInMemory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MobileVaultStore(directory: directory)
    await store.start()
    await store.authenticate("Synthetic draft test 123!", create: true)
    XCTAssertTrue(store.unlocked)
    var note = VaultItem.blank(type: "secureNote", title: "Pending")
    note.note = "Only an encrypted recovery can survive lock"
    store.pendingDraft = note
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("mobile-draft.sealed"), withIntermediateDirectories: true
    )
    store.lock()
    await store.authenticate("Synthetic draft test 123!", create: false)
    XCTAssertTrue(store.unlocked)
    XCTAssertEqual(store.recoveredDraft?.note, note.note)
    XCTAssertEqual(store.items.count, 0, "Recovery must not silently commit a draft")
    store.discardDraft()
    await store.close()
    try FileManager.default.removeItem(at: directory)
  }
  func testDamagedDraftDoesNotBlockVaultUnlock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MobileVaultStore(directory: directory)
    await store.start()
    await store.authenticate("Synthetic draft test 123!", create: true)
    try Data("invalid draft".utf8).write(
      to: directory.appendingPathComponent("mobile-draft.sealed"))
    store.lock()
    await store.authenticate("Synthetic draft test 123!", create: false)
    XCTAssertTrue(store.unlocked)
    XCTAssertNotNil(store.error)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("mobile-draft.sealed").path))
    await store.close()
    try FileManager.default.removeItem(at: directory)
  }
}
