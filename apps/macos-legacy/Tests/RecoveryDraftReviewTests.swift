import Foundation
import XCTest
@testable import PasswordVault

@MainActor
final class RecoveryDraftReviewTests: XCTestCase {
  private let password = "Synthetic draft conflict fixture"
  private func call(_ session: VaultSession, _ request: [String: JSONValue]) throws -> JSONValue {
    let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    return try JSONDecoder().decode(JSONValue.self, from: Data(session.command(request: text).utf8))
  }
  private func fixture(_ folder: URL, crossLibrary: Bool = false) throws -> Data {
    let session = try VaultSession(directory: folder.path)
    _ = try call(session, ["op": .string("create"), "password": .string(password)])
    let founder = try call(session, ["op": .string("relay-peer-create"), "device": .string("draft-qa"), "personal": .bool(true), "migrateLegacy": .bool(true)])
    var note = VaultItem.blank(type: "secureNote", title: "Draft fixture")
    note.fields["id"] = .string("same-fixture-id")
    note.note = "Original"
    _ = try call(session, ["op": .string("save"), "item": try .from(note)])
    let listed = try call(session, ["op": .string("list")])
    var original = VaultItem(fields: listed.object["items"]!.array[0].object)
    var draft = original
    draft.note = "Unsaved draft"
    let sealed = try call(session, ["op": .string("seal-drafts"), "items": try .from([draft])])
    // Local autosaves may advance the same author's causal chain. Exercise an
    // actual remote author so this fixture proves stale recovery, not that path.
    let remoteFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: remoteFolder) }
    let remote = try VaultSession(directory: remoteFolder.path)
    _ = try call(remote, ["op": .string("create"), "password": .string("Synthetic remote draft fixture")])
    let identity = try call(remote, ["op": .string("relay-peer-identity"), "device": .string("draft-remote"), "personal": .bool(true), "confirmPersonalSync": .bool(true)])
    let library = try XCTUnwrap(founder.object["library"])
    _ = try call(session, ["op": .string("relay-peer-authorize"), "library": library, "peer": .string("draft-remote"), "member": .object(["publicKey": try XCTUnwrap(identity.object["publicKey"]), "role": .string("editor")])])
    let initial = try call(session, ["op": .string("relay-peer-export"), "library": library, "peer": .string("draft-remote")])
    _ = try call(remote, ["op": .string("relay-peer-join"), "library": try XCTUnwrap(identity.object["library"]), "expectedLibrary": library, "founderKey": try XCTUnwrap(founder.object["publicKey"]), "envelope": initial])
    let remoteListed = try call(remote, ["op": .string("list")])
    original = VaultItem(fields: remoteListed.object["items"]!.array[0].object)
    original.note = "Newer current version"
    _ = try call(remote, ["op": .string("save"), "item": try .from(original)])
    let changed = try call(remote, ["op": .string("relay-peer-export"), "library": library, "peer": .string("draft-qa")])
    _ = try call(session, ["op": .string("relay-peer-receive"), "library": library, "envelope": changed])
    _ = try call(remote, ["op": .string("lock")])
    if crossLibrary {
      let family = try call(session, ["op": .string("relay-peer-create"), "device": .string("draft-qa"), "personal": .bool(false), "name": .string("Other family")])
      _ = try call(session, ["op": .string("relay-peer-switch"), "library": family.object["library"]!])
      var other = VaultItem.blank(type: "secureNote", title: "Different library record")
      other.fields["id"] = .string("same-fixture-id")
      other.note = "Must not be replaced"
      _ = try call(session, ["op": .string("save"), "item": try .from(other)])
    }
    _ = try call(session, ["op": .string("lock")])
    let bytes = try JSONEncoder().encode(sealed)
    try bytes.write(to: folder.appendingPathComponent("draft-recovery.json"), options: .atomic)
    return bytes
  }

  func testExplicitReviewCreatesNewVersionAndKeepsCurrentInHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let originalCipher = try fixture(folder)
    let store = AppStore(directory: folder)
    await store.authenticate(password: password, create: false)
    XCTAssertTrue(store.unlocked)
    XCTAssertTrue(store.recoveryReviewPending)
    XCTAssertFalse(store.canWriteLibrary)
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("draft-recovery.json")), originalCipher)
    let row = try XCTUnwrap(store.recoveryReviewRows.first)
    XCTAssertEqual(row.current?.note, "Newer current version")
    XCTAssertEqual(row.draft.note, "Unsaved draft")
    XCTAssertTrue(row.canRestore)
    await store.restoreReviewedDraft(row.id)
    XCTAssertNil(store.recoveryReviewError)
    XCTAssertFalse(store.recoveryReviewPending)
    XCTAssertTrue(store.canWriteLibrary)
    XCTAssertEqual(store.items.first?.note, "Unsaved draft")
    let history = try await store.perform(["op": .string("history-list"), "id": .string(row.draft.id)])
    XCTAssertTrue(history.object["revisions"]!.array.contains { $0.object["item"]?.object["note"]?.string == "Newer current version" })
    store.lock(); await store.finishLock()
  }

  func testChangeAfterReviewStillRejectsAndDiscardDoesNotChangeLiveRecord() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let originalCipher = try fixture(folder)
    let store = AppStore(directory: folder)
    await store.authenticate(password: password, create: false)
    let row = try XCTUnwrap(store.recoveryReviewRows.first)
    var newer = try XCTUnwrap(row.current)
    newer.note = "Changed after review"
    _ = try await store.perform(["op": .string("save"), "item": try .from(newer)])
    await store.restoreReviewedDraft(row.id)
    XCTAssertNotNil(store.recoveryReviewError)
    XCTAssertTrue(store.recoveryReviewPending)
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("draft-recovery.json")), originalCipher)
    await store.refresh()
    XCTAssertEqual(store.items.first?.note, "Changed after review")
    await store.discardReviewedDraft(row.id)
    XCTAssertFalse(store.recoveryReviewPending)
    XCTAssertEqual(store.items.first?.note, "Changed after review")
    store.lock(); await store.finishLock()
  }

  func testSameIDInDifferentLibraryCannotConsumePersonalDraft() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let originalCipher = try fixture(folder, crossLibrary: true)
    let store = AppStore(directory: folder)
    await store.authenticate(password: password, create: false)
    let row = try XCTUnwrap(store.recoveryReviewRows.first)
    XCTAssertFalse(row.canRestore)
    XCTAssertEqual(row.blocked, "library")
    await store.restoreReviewedDraft(row.id)
    XCTAssertEqual(store.items.first?.note, "Must not be replaced")
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("draft-recovery.json")), originalCipher)
    store.lock(); await store.finishLock()
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("draft-recovery.json").path))
  }

  func testFailedResealRetainsCiphertextAndPendingRow() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); try? FileManager.default.removeItem(at: folder) }
    let originalCipher = try fixture(folder)
    let store = AppStore(directory: folder)
    await store.authenticate(password: password, create: false)
    let row = try XCTUnwrap(store.recoveryReviewRows.first)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    await store.discardReviewedDraft(row.id)
    XCTAssertNotNil(store.recoveryReviewError)
    XCTAssertTrue(store.recoveryReviewPending)
    XCTAssertEqual(store.recoveryReviewRows.count, 1)
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("draft-recovery.json")), originalCipher)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    store.lock(); await store.finishLock()
  }

  func testMissingDeletedUnmarkedAndReadOnlyTargetsFailClosed() {
    var draft = VaultItem.blank(type: "secureNote", title: "Fixture")
    draft.fields["id"] = .string("fixed")
    draft.fields["_peerLibrary"] = .string("family")
    draft.fields["_peerBaseHeads"] = .array([.string("old-head")])
    var current = draft
    current.fields["_peerBaseHeads"] = .array([.string("new-head")])
    func document(_ values: [VaultItem], readOnly: Bool = false) -> VaultDocument {
      VaultDocument(items: values, settings: ["activePeerLibrary": .string("family"), "_peerLibraryRole": .string(readOnly ? "reader" : "editor"), "_peerLibraryReadOnly": .bool(readOnly)], sharedVaults: [], sharedMembers: [])
    }
    XCTAssertTrue(RecoveryDraftReviewRow(draft: draft, document: document([current])).canRestore)
    XCTAssertEqual(RecoveryDraftReviewRow(draft: draft, document: document([])).blocked, "missing")
    XCTAssertEqual(RecoveryDraftReviewRow(draft: draft, document: document([current], readOnly: true)).blocked, "permission")
    var deleted = current; deleted.isDeleted = true
    XCTAssertEqual(RecoveryDraftReviewRow(draft: draft, document: document([deleted])).blocked, "deleted")
    var unmarked = draft; unmarked.fields.removeValue(forKey: "_peerLibrary"); unmarked.fields.removeValue(forKey: "_peerBaseHeads")
    XCTAssertEqual(RecoveryDraftReviewRow(draft: unmarked, document: document([current])).blocked, "library")
    XCTAssertEqual(RecoveryDraftReviewRow(draft: unmarked, document: document([unmarked])).blocked, "library")
  }
}
