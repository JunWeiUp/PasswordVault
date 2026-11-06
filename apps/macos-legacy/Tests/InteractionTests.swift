import XCTest

@testable import PasswordVault

@MainActor
final class InteractionTests: XCTestCase {
  func testNeverIdleLockPersistsAndManualLockStillWorks() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    store.settings["macNeverIdleLock"] = .bool(true)
    await store.saveSettings()
    XCTAssertNil(store.error)
    store.checkIdleLock(now: Date().addingTimeInterval(86400 * 30))
    XCTAssertTrue(store.unlocked)
    store.lock()
    await store.finishLock()
    XCTAssertFalse(store.unlocked)
    await store.authenticate(password: password, create: false)
    XCTAssertEqual(store.settings["macNeverIdleLock"], .bool(true))
    store.checkIdleLock(now: Date().addingTimeInterval(86400))
    XCTAssertTrue(store.unlocked)
    store.settings["macNeverIdleLock"] = .bool(false)
    store.settings["autoLockMinutes"] = .number(1)
    store.checkIdleLock(now: Date().addingTimeInterval(61))
    XCTAssertFalse(store.unlocked)
    await store.finishLock()
  }

  func testPreviewEditAndImmediateLockPersistsInput() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    var note = VaultItem.blank(type: "secureNote", title: "Inline fixture")
    let original = "# Title\n\n- **one**\n\n[link](https://example.test)\n"
    note.note = original
    note.set("noteFormat", "markdown")
    try await store.saveRecord(note)
    note.note = original.replacingOccurrences(of: "- **one**", with: "- **two**\n- three")
    store.editNote(note)
    store.lock()
    await store.finishLock()
    await store.authenticate(password: password, create: false)
    XCTAssertEqual(store.items.first?.note, "# Title\n\n- **two**\n- three\n\n[link](https://example.test)\n")
    store.lock(); await store.finishLock()
  }

  func testOneHourIdleLockAndExplicitBrowserActivity() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    store.settings["autoLockMinutes"] = .number(60)
    let start = Date()
    store.checkIdleLock(now: start.addingTimeInterval(59 * 60))
    XCTAssertTrue(store.unlocked)
    store.recordBrowserActivity(now: start.addingTimeInterval(59 * 60))
    store.checkIdleLock(now: start.addingTimeInterval(90 * 60))
    XCTAssertTrue(store.unlocked)
    store.checkIdleLock(now: start.addingTimeInterval(119 * 60 + 1))
    XCTAssertFalse(store.unlocked)
    await store.finishLock()
  }

  func testAllEntryTypesCanMoveToTrashAndRestoreWithoutLosingContent() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    for type in ["secureNote", "password", "totp", "crypto"] {
      var item = VaultItem.blank(type: type, title: "Synthetic delete " + type)
      item.note = "Synthetic retained content"
      try await store.saveRecord(item)
      await store.trash(item)
      let deleted = try XCTUnwrap(store.items.first { $0.id == item.id })
      XCTAssertTrue(deleted.isDeleted)
      XCTAssertEqual(deleted.note, item.note)
      await store.trash(deleted)
      XCTAssertFalse(try XCTUnwrap(store.items.first { $0.id == item.id }).isDeleted)
      XCTAssertEqual(store.selectedID, item.id)
    }
    store.lock()
    await store.finishLock()
  }

  private let password = "Synthetic interaction fixture!"

  private func fixture() async -> (AppStore, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = AppStore(directory: folder)
    await store.authenticate(password: password, create: true)
    XCTAssertTrue(store.unlocked)
    return (store, folder)
  }

  func testTrashSearchAndRestoreNavigateToTheRestoredRecord() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = VaultItem.blank(type: "secureNote", title: "Family insurance")
    let second = VaultItem.blank(type: "password", title: "Work account")
    try await store.saveRecord(first)
    try await store.saveRecord(second)
    await store.trash(first)
    await store.trash(second)
    store.navigate(.trash)
    store.search = "insurance"
    XCTAssertEqual(store.visibleItems.map(\.id), [first.id])
    store.search = "no such entry"
    XCTAssertTrue(store.visibleItems.isEmpty)
    store.search = ""
    XCTAssertEqual(store.visibleItems.count, 2)
    await store.trash(try XCTUnwrap(store.items.first { $0.id == second.id }))
    XCTAssertEqual(store.destination.itemType, "password")
    XCTAssertEqual(store.selectedID, second.id)
    XCTAssertEqual(store.visibleItems.map(\.id), [second.id])
    store.lock()
    await store.finishLock()
  }

  func testDirectCreationAndRepeatedAutosaveKeepOneEntry() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    store.destination = .passwords
    store.search = "old search"
    await store.newItem()
    let id = try XCTUnwrap(store.selectedID)
    var entry = try XCTUnwrap(store.items.first)
    XCTAssertEqual(entry.id, id)
    XCTAssertTrue(store.search.isEmpty)
    entry.username = "fixture@example.test"
    store.editEntry(entry)
    await store.flushChanges(); await store.flushChanges()
    XCTAssertEqual(store.items.count, 1)
    let saved = try await store.core?.document()
    XCTAssertEqual(saved?.items.first?.username, "fixture@example.test")
    store.lock(); await store.finishLock()
  }

  func testExportFlushesLatestEditAndWriteFailureBlocksExportUntilRetry() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    var note = VaultItem.blank(type: "secureNote", title: "Pending draft")
    try await store.saveRecord(note)
    note.note = "Latest text before export"
    store.editNote(note)
    let exported = try await store.perform(["op": .string("export-plain"), "kind": .string("json")])
    XCTAssertTrue(exported.object["content"]?.string.contains(note.note) == true)
    XCTAssertFalse(store.saving)
    let vaultFolder = folder.appendingPathComponent("vault")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: vaultFolder.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: vaultFolder.path)
    }
    note.note = "Must survive a failed write"
    store.editNote(note)
    do {
      _ = try await store.perform(["op": .string("export"), "password": .string(password)])
      XCTFail("Export must stop when accepted edits cannot be persisted")
    } catch { XCTAssertTrue(error is VaultError) }
    XCTAssertTrue(store.saveFailed)
    XCTAssertEqual(store.items.first?.note, note.note)
    XCTAssertNil(store.error, "Autosave failures belong beside Retry, not in a generic alert")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: vaultFolder.path)
    await store.flushChanges()
    XCTAssertFalse(store.saveFailed)
    XCTAssertFalse(store.saving)
    let retry = try await store.perform(["op": .string("export-plain"), "kind": .string("json")])
    XCTAssertTrue(retry.object["content"]?.string.contains(note.note) == true)
    store.lock()
    await store.finishLock()
  }

  func testPendingEditSurvivesFavoriteMetadataTrashAndImport() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    var note = VaultItem.blank(type: "secureNote", title: "Race fixture")
    try await store.saveRecord(note)
    note.note = "Immediately before favorite"
    store.editNote(note)
    await store.toggleFavorite(note.id)
    XCTAssertTrue(store.items[0].isFavorite)
    XCTAssertEqual(store.items[0].note, note.note)
    var metadata = store.items[0]
    metadata.category = "Updated category"
    try await store.saveRecord(metadata)
    await store.trash(note)
    XCTAssertEqual(store.items[0].note, note.note)
    XCTAssertEqual(store.items[0].category, metadata.category)
    XCTAssertTrue(store.items[0].isDeleted)
    await store.trash(store.items[0])
    var updated = store.items[0]
    updated.note = "Immediately before merging an older backup"
    store.editNote(updated)
    let older =
      "{\"items\":[{\"id\":\"\(note.id)\",\"type\":\"secureNote\",\"title\":\"Old\",\"note\":\"Stale body\",\"updatedAt\":\"2000-01-01T00:00:00Z\"}]}"
    _ = try await store.perform([
      "op": .string("import"), "content": .string(older), "password": .string(""),
    ])
    await store.refresh()
    XCTAssertEqual(store.items[0].note, updated.note)
    XCTAssertTrue(store.items[0].isFavorite)
    store.lock()
    await store.finishLock()
    await store.authenticate(password: password, create: false)
    XCTAssertEqual(store.items[0].note, updated.note)
    XCTAssertFalse(store.items[0].isDeleted)
    store.lock()
    await store.finishLock()
  }

  func testSavingAnotherRecordDoesNotStrandAPendingNote() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    var note = VaultItem.blank(type: "secureNote", title: "First record")
    try await store.saveRecord(note)
    note.note = "Must persist while another editor saves"
    store.editNote(note)
    let other = VaultItem.blank(type: "password", title: "Second record")
    try await store.saveRecord(other)
    let persisted = try await store.core?.document()
    XCTAssertEqual(persisted?.items.first { $0.id == note.id }?.note, note.note)
    XCTAssertFalse(store.saving)
    store.lock()
    await store.finishLock()
  }

  func testPermanentDeleteOfDisposableRecordPersistsAndSettingsFailureRollsBack() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    var note = VaultItem.blank(type: "secureNote", title: "Disposable deletion fixture")
    note.isDeleted = true
    try await store.saveRecord(note)
    await store.removePermanently(note)
    XCTAssertTrue(store.items.isEmpty)
    let persisted = try await store.core?.document()
    XCTAssertTrue(persisted?.items.isEmpty == true)
    store.settings["theme"] = .string("light")
    let saved = await store.saveSettings()
    XCTAssertTrue(saved)
    let vaultFolder = folder.appendingPathComponent("vault")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: vaultFolder.path)
    store.settings["theme"] = .string("dark")
    let failed = await store.saveSettings()
    XCTAssertFalse(failed)
    XCTAssertEqual(store.settings["theme"]?.string, "light")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: vaultFolder.path)
    store.lock()
    await store.finishLock()
    await store.authenticate(password: password, create: false)
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertEqual(store.settings["theme"]?.string, "light")
    store.lock()
    await store.finishLock()
  }

  func testWrongPasswordHasInlineRecoveryAndSuccessfulRetryClearsIt() async throws {
    let (store, folder) = await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    store.lock()
    await store.finishLock()
    await store.authenticate(password: "Incorrect synthetic password", create: false)
    XCTAssertFalse(store.unlocked)
    XCTAssertNotNil(store.authenticationError)
    XCTAssertNil(store.error)
    await store.authenticate(password: password, create: false)
    XCTAssertTrue(store.unlocked)
    XCTAssertNil(store.authenticationError)
    store.lock()
    await store.finishLock()
  }
}
