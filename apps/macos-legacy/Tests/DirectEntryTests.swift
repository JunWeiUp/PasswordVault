import XCTest
@testable import PasswordVault

@MainActor
final class DirectEntryTests: XCTestCase {
  private let password = "Synthetic direct-entry fixture"
  func testAllTypesCreateImmediatelyAndSurviveLockBeforeFilling() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder); await store.authenticate(password: password, create: true)
    var ids = Set<String>()
    for target in [Destination.notes, .passwords, .codes, .wallets] {
      store.navigate(target); await store.newItem()
      let id = try XCTUnwrap(store.selectedID); ids.insert(id)
      let item = try XCTUnwrap(store.items.first { $0.id == id })
      XCTAssertEqual(item.type, target.itemType); XCTAssertFalse(item.title.isEmpty)
      XCTAssertEqual(store.editingNewNoteID, id)
    }
    store.lock(); await store.finishLock(); await store.authenticate(password: password, create: false)
    XCTAssertEqual(Set(store.items.map(\.id)), ids)
    store.lock(); await store.finishLock()
  }
  func testAutosaveHistoryUsesSessionBaselineAndAdditionalStableIDs() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder); await store.authenticate(password: password, create: true)
    var original = VaultItem.blank(type: "totp", title: "Fixture")
    original.password = "old-primary"
    original.fields["accounts"] = .array([.object(["id": .string("extra"), "password": .string("old-extra")])])
    try await store.saveRecord(original)
    for typed in ["n", "ne", "new-primary"] {
      var value = try XCTUnwrap(store.items.first); value.password = typed
      value.fields["accounts"] = .array([.object(["id": .string("extra"), "label": .string("Work"), "password": .string("new-extra")])])
      value.set("email", "fixture@example.test"); value.set("url", "https://one.example.test\nhttps://two.example.test")
      store.editEntry(value); await store.flushChanges()
    }
    let edited = try XCTUnwrap(store.items.first)
    XCTAssertEqual(edited.fields["passwordHistory"]?.array.count, 1)
    XCTAssertEqual(edited.fields["passwordHistory"]?.array.first?.object["password"]?.string, "old-primary")
    XCTAssertEqual(edited.fields["accounts"]?.array.first?.object["passwordHistory"]?.array.count, 1)
    store.lock(); await store.finishLock(); await store.authenticate(password: password, create: false)
    XCTAssertEqual(store.items.first?.password, "new-primary")
    XCTAssertEqual(store.items.first?.string("email"), "fixture@example.test")
    XCTAssertEqual(store.items.first?.fields["accounts"]?.array.first?.object["id"]?.string, "extra")
    store.lock(); await store.finishLock()
  }
  func testHistoryDoesNotAccumulateOnRetryOrFirstPassword() {
    var empty = VaultItem.blank(type: "password", title: "Fixture"); empty.password = "new"
    let first = EntryPasswordHistory.prepare(empty, baseline: VaultItem.blank(type: "password", title: "Fixture"), changedAt: "fixture-time")
    XCTAssertEqual(first.fields["passwordHistory"]?.array.count, 0)
    XCTAssertEqual(first.string("passwordLastChanged"), "fixture-time")
    XCTAssertEqual(EntryPasswordHistory.prepare(first, baseline: first, changedAt: "retry-time"), first)
  }
  func testRevertingPrimaryAndExtraPasswordRestoresAbsentHistory() {
    var original = VaultItem.blank(type: "password", title: "Fixture")
    original.password = "A"
    original.fields["accounts"] = .array([.object(["id": .string("extra"), "password": .string("A")])])
    var draft = original; draft.password = "B"
    draft.fields["accounts"] = .array([.object(["id": .string("extra"), "password": .string("B")])])
    var changed = EntryPasswordHistory.prepare(draft, baseline: original, changedAt: "fixture")
    changed.password = "A"
    var account = changed.fields["accounts"]!.array[0].object; account["password"] = .string("A")
    changed.fields["accounts"] = .array([.object(account)])
    let reverted = EntryPasswordHistory.prepare(changed, baseline: original, changedAt: "fixture")
    XCTAssertNil(reverted.fields["passwordHistory"])
    XCTAssertNil(reverted.fields["passwordLastChanged"])
    XCTAssertNil(reverted.fields["accounts"]!.array[0].object["passwordHistory"])
  }

  func testExternalRefreshDoesNotOverwriteNewCredentialHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder); await store.authenticate(password: password, create: true)
    var original = VaultItem.blank(type: "password", title: "Fixture"); original.password = "A"
    try await store.saveRecord(original)
    original.note = "local note"; store.editEntry(original); await store.flushChanges()
    var external = original; external.password = "C"
    external.fields["passwordHistory"] = .array([.object(["password": .string("B"), "changedAt": .string("external")])])
    external.fields["passwordLastChanged"] = .string("external")
    _ = try await store.perform(["op": .string("save"), "item": try .from(external)])
    await store.refresh()
    var local = try XCTUnwrap(store.items.first); local.set("email", "fixture@example.test"); store.editEntry(local)
    XCTAssertEqual(store.items.first?.password, "C")
    XCTAssertEqual(store.items.first?.fields["passwordHistory"], external.fields["passwordHistory"])
    XCTAssertEqual(store.items.first?.fields["passwordLastChanged"], external.fields["passwordLastChanged"])
    store.lock(); await store.finishLock()
  }

  func testLegacyAccountIDsBecomeUniqueWithoutLosingUnknownFieldsOrHistory() {
    var record = VaultItem.blank(type: "password", title: "Fixture")
    let history: JSONValue = .array([.object(["password": .string("older")])])
    record.fields["accounts"] = .array([
      .object(["password": .string("one"), "passwordHistory": history, "custom": .string("retained")]),
      .object(["id": .string("duplicate"), "password": .string("two")]),
      .object(["id": .string("duplicate"), "password": .string("three")])])
    let fixed = EntryPasswordHistory.normalizeAccountIDs(record)
    let ids = fixed.fields["accounts"]!.array.map { $0.object["id"]!.string }
    XCTAssertEqual(Set(ids).count, 3); XCTAssertFalse(ids.contains(""))
    XCTAssertEqual(EntryPasswordHistory.normalizeAccountIDs(fixed), fixed)
    let prepared = EntryPasswordHistory.prepare(fixed, baseline: record, changedAt: "fixture")
    XCTAssertEqual(prepared.fields["accounts"]!.array[0].object["passwordHistory"], history)
    XCTAssertEqual(prepared.fields["accounts"]!.array[0].object["custom"]?.string, "retained")
  }

  func testBrowserEditNavigatesExactRecordAndAdditionalAccountWithoutMutatingSecrets() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder); await store.authenticate(password: password, create: true)
    var record = VaultItem.blank(type: "password", title: "Browser editor fixture")
    record.username = "primary@example.test"; record.password = "Synthetic primary"
    record.set("url", "https://example.test:8443")
    record.fields["accounts"] = .array([.object(["id": .string("extra"), "username": .string("extra@example.test"), "password": .string("Synthetic extra")])])
    try await store.saveRecord(record)
    store.navigate(.notes, category: "unrelated"); store.search = "unmatched query"
    let original = store.items.first
    let opened = try await store.openBrowserEntry(id: record.id, accountID: "extra", origin: "https://example.test:443")
    XCTAssertTrue(opened); XCTAssertEqual(store.destination, .passwords)
    XCTAssertEqual(store.selectedID, record.id); XCTAssertEqual(store.browserAccountAnchor, "account:extra")
    XCTAssertNil(store.category); XCTAssertEqual(store.search, ""); XCTAssertEqual(store.items.first, original)
    let before = store.browserNavigationID
    _ = try await store.openBrowserEntry(id: record.id, accountID: "extra", origin: "https://example.test")
    XCTAssertNotEqual(before, store.browserNavigationID)
    let mismatch = try await store.openBrowserEntry(id: record.id, accountID: nil, origin: "https://other.test")
    XCTAssertFalse(mismatch)
    let badExtra = try await store.openBrowserEntry(id: record.id, accountID: "missing", origin: "https://example.test")
    XCTAssertFalse(badExtra)
    var pendingRemoval = try XCTUnwrap(store.items.first)
    pendingRemoval.fields["accounts"] = .array([]); store.editEntry(pendingRemoval)
    let removedExtra = try await store.openBrowserEntry(id: record.id, accountID: "extra", origin: "https://example.test")
    XCTAssertFalse(removedExtra)
    await store.trash(record)
    let deleted = try await store.openBrowserEntry(id: record.id, accountID: nil, origin: "https://example.test")
    XCTAssertFalse(deleted)
    store.lock(); await store.finishLock()
    let locked = try await store.openBrowserEntry(id: record.id, accountID: nil, origin: "https://example.test")
    XCTAssertFalse(locked); XCTAssertNil(store.browserAccountAnchor)
  }

}
