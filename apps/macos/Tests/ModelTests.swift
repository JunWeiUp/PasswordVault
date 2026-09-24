import XCTest

@testable import PasswordVault

final class ModelTests: XCTestCase {
  func testUnknownFieldsSurviveEditing() throws {
    let json =
      #"{"id":"one","type":"secureNote","title":"Before","futureField":{"value":true},"note":"Synthetic"}"#
    var item = try JSONDecoder().decode(VaultItem.self, from: Data(json.utf8))
    item.title = "After"
    let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
    XCTAssertEqual(decoded.object["futureField"]?.object["value"], .bool(true))
    XCTAssertEqual(decoded.object["title"], .string("After"))
  }
  func testWebdavRejectsInsecureRemoteAndPathTraversal() {
    XCTAssertThrowsError(
      try WebDAVClient(
        url: "http://example.com", username: "test", password: "test", folder: "backup"))
    XCTAssertThrowsError(
      try WebDAVClient(
        url: "https://example.com", username: "test", password: "test", folder: "../escape"))
    XCTAssertNoThrow(
      try WebDAVClient(
        url: "https://example.com/dav", username: "test", password: "test", folder: "backup"))
  }
}
