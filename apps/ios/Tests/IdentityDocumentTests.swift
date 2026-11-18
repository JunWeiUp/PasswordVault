import XCTest

@testable import PasswordVault

final class IdentityDocumentTests: XCTestCase {
  func testSchemaMatchesTheOtherClients() {
    XCTAssertEqual(
      IdentityDocument.fields.map { "\($0.id):\($0.kind):\($0.label)" },
      [
        "document.type:text:证件类型", "document.number:concealed:证件号码", "document.issuer:text:签发机关",
        "document.issueDate:date:签发日期", "document.expiryDate:date:有效期至",
      ])
    XCTAssertEqual(IdentityDocument.group, "document")
  }

  func testSettingCreatesFieldsOnlyWithValues() {
    XCTAssertEqual(IdentityDocument.setting([], "document.issuer", ""), [], "Empty values add nothing")
    let created = IdentityDocument.setting([], "document.number", "E1")
    XCTAssertEqual(created, [
      .object([
        "id": .string("document.number"), "group": .string("document"), "label": .string("证件号码"),
        "kind": .string("concealed"), "value": .string("E1"),
      ])
    ])
    XCTAssertEqual(IdentityDocument.setting([], "document.photo", "x"), [], "Unknown ids are ignored")
  }

  func testEditingPreservesOtherFieldsLabelsAndUnknownKeys() {
    let legacy: JSONValue = .object([
      "id": .string("legacy"), "label": .string("旧"), "kind": .string("text"), "value": .string("x"),
      "extra": .number(1),
    ])
    let relabeled: JSONValue = .object([
      "id": .string("document.type"), "group": .string("document"), "label": .string("Document type"),
      "kind": .string("text"), "value": .string("Passport"), "future": .bool(true),
    ])
    let updated = IdentityDocument.setting([legacy, relabeled], "document.type", "护照")
    XCTAssertEqual(updated[0], legacy)
    var expected = relabeled.object
    expected["value"] = .string("护照")
    XCTAssertEqual(updated[1], .object(expected), "Stored label and unknown keys survive")
    XCTAssertEqual(IdentityDocument.value(updated, "document.type"), "护照")
    let appended = IdentityDocument.setting(updated, "document.expiryDate", "2031-02-28")
    XCTAssertEqual(Array(appended.prefix(2)), updated, "Existing fields keep their order")
    XCTAssertTrue(IdentityDocument.isDocument(appended[2]))
    XCTAssertFalse(IdentityDocument.isDocument(legacy))
    XCTAssertEqual(IdentityDocument.label(relabeled, t: { zh, _ in zh }), "证件类型", "Known ids show localized labels")
    XCTAssertEqual(IdentityDocument.label(relabeled, t: { _, en in en }), "Document type")
    XCTAssertEqual(IdentityDocument.label(legacy, t: { _, en in en }), "旧")
  }

  func testDatesUseYearMonthDay() {
    XCTAssertTrue(IdentityDocument.validDate(""))
    XCTAssertTrue(IdentityDocument.validDate("2031-02-28"))
    XCTAssertTrue(IdentityDocument.validDate("2028-02-29"))
    XCTAssertFalse(IdentityDocument.validDate("2031-02-30"))
    XCTAssertFalse(IdentityDocument.validDate("2031/02/01"))
    XCTAssertFalse(IdentityDocument.validDate("31-02-01"))
    XCTAssertEqual(IdentityDocument.string(IdentityDocument.date("2030-12-31")!), "2030-12-31")
  }

  /// The core keeps document fields and foreign custom fields, and keeps the number encrypted.
  func testCoreStoresDocumentsAsCustomFieldsAndRejectsUnknownIdentityKeys() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let core = try MobileCore(directory: directory)
    _ = try await core.call(["op": .string("create"), "password": .string("Synthetic identity test 123!")])
    var person = VaultItem.blank(type: "identity", title: "QA identity")
    person.fields["identity"] = .object(["firstName": .string("Alex"), "lastName": .string("Example")])
    let foreign: JSONValue = .object([
      "id": .string("legacy-1"), "label": .string("会员号"), "kind": .string("text"), "value": .string("M-1"),
    ])
    var fields = IdentityDocument.setting([foreign], "document.type", "护照")
    fields = IdentityDocument.setting(fields, "document.number", "E7654321-CANARY")
    fields = IdentityDocument.setting(fields, "document.expiryDate", "2031-02-28")
    person.fields["customFields"] = .array(fields)
    _ = try await core.call(["op": .string("save"), "item": try .from(person)])
    let saved = try await core.document().items.first { $0.id == person.id }
    let stored = saved?.fields["customFields"]?.array ?? []
    XCTAssertEqual(stored.first, foreign)
    XCTAssertEqual(IdentityDocument.value(stored, "document.number"), "E7654321-CANARY")
    XCTAssertEqual(IdentityDocument.value(stored, "document.expiryDate"), "2031-02-28")
    XCTAssertEqual(saved?.fields["identity"]?.object["firstName"]?.string, "Alex")

    // Failure path: a document key inside the identity record is rejected, data unchanged.
    var invalid = person
    invalid.fields["identity"] = .object(["firstName": .string("Alex"), "documentNumber": .string("X")])
    do {
      _ = try await core.call(["op": .string("save"), "item": try .from(invalid)])
      XCTFail("Unknown identity keys must be rejected")
    } catch {}
    let after = try await core.document().items.first { $0.id == person.id }
    XCTAssertEqual(after?.fields["customFields"], saved?.fields["customFields"])
    await core.close()
    for url in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [] {
      if let data = try? Data(contentsOf: url) {
        XCTAssertNil(data.range(of: Data("E7654321-CANARY".utf8)), "The number is never stored in plain text")
      }
    }
  }
}
