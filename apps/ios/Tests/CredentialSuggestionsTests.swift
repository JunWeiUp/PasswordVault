import XCTest

@testable import PasswordVault

final class CredentialSuggestionsTests: XCTestCase {
  private func json(_ value: Any) -> JSONValue {
    switch value {
    case let v as String: return .string(v)
    case let v as Bool: return .bool(v)
    case let v as [[String: Any]]: return .array(v.map { json($0) })
    case let v as [String: Any]: return .object(v.mapValues { json($0) })
    default: return .null
    }
  }
  private func item(_ fields: [String: Any]) -> VaultItem { VaultItem(fields: fields.mapValues { json($0) }) }

  func testIndexesSiteUsernameAndEntryIDButNeverThePassword() {
    let account = item([
      "id": "a1", "type": "password", "title": "Example", "username": "alex@example.test",
      "password": "SYNTHETIC-PASSWORD-CANARY", "url": "https://login.example.com/path",
      "accounts": [["username": "team@example.test", "password": "SECOND-CANARY"]],
    ])
    let entries = CredentialSuggestions.entries([account])
    XCTAssertEqual(entries, [
      .init(host: "login.example.com", user: "alex@example.test", record: "a1"),
      .init(host: "login.example.com", user: "team@example.test", record: "a1#1"),
    ])
    XCTAssertFalse(String(describing: entries).contains("CANARY"))
  }

  func testSkipsDeletedNonAccountsMissingSitesAndEmptyUsernames() {
    let items = [
      item(["id": "d", "type": "password", "username": "u", "url": "https://a.example", "isDeleted": true]),
      item(["id": "n", "type": "secureNote", "username": "u", "url": "https://a.example"]),
      item(["id": "s", "type": "password", "username": "u", "url": ""]),
      item(["id": "f", "type": "password", "username": "u", "url": "ftp://files.example"]),
      item(["id": "e", "type": "password", "username": "", "url": "https://a.example"]),
    ]
    XCTAssertTrue(CredentialSuggestions.entries(items).isEmpty)
  }

  func testHostParsing() {
    XCTAssertEqual(CredentialSuggestions.host("example.com"), "example.com")
    XCTAssertEqual(CredentialSuggestions.host("HTTPS://Example.COM:8443/x"), "example.com")
    XCTAssertEqual(CredentialSuggestions.host("\nhttps://second.example\n"), "second.example")
    XCTAssertNil(CredentialSuggestions.host("https://user:pw@example.com"))
    XCTAssertNil(CredentialSuggestions.host("mailto:alex@example.com"))
  }
}
