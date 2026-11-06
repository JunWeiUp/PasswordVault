import XCTest

@testable import PasswordVault

final class PasswordBreachCheckTests: XCTestCase {
  func testLookupDeduplicatesPrefixAndChecksAdditionalAccounts() async throws {
    var item = VaultItem.blank(type: "password", title: "Fixture")
    item.password = "password"
    item.fields["accounts"] = .array([.object(["password": .string("password")])])
    var requests = 0
    let result = try await PasswordBreachCheck.check([item]) { request in
      requests += 1
      XCTAssertEqual(request.url?.path, "/range/5BAA6")
      let body = Data("1E4C9B93F3F0682250B6CF8331B7EE68FD8:10\r\n".utf8)
      return (
        body,
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(result, [item.id])
  }
  func testServiceErrorsCannotProduceCleanResults() async throws {
    var item = VaultItem.blank(type: "password", title: "Fixture")
    item.password = "password"
    for status in [302, 429, 500] {
      do {
        _ = try await PasswordBreachCheck.check([item]) { request in
          (
            Data(),
            HTTPURLResponse(
              url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
          )
        }
        XCTFail("HTTP failure must not be reported as a clean result")
      } catch {}
    }
  }
  func testRequestContainsOnlyHashPrefixAndUsesPadding() throws {
    let digest = PasswordBreachCheck.hash("password")
    XCTAssertEqual(digest, "5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8")
    let request = try PasswordBreachCheck.request(prefix: String(digest.prefix(5)))
    XCTAssertEqual(request.url?.absoluteString, "https://api.pwnedpasswords.com/range/5BAA6")
    XCTAssertNil(request.httpBody)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Add-Padding"), "true")
    XCTAssertThrowsError(try PasswordBreachCheck.request(prefix: "../bad"))
    XCTAssertThrowsError(try PasswordBreachCheck.request(prefix: digest))
  }
  func testMalformedResponseIsFailureAndPaddingDoesNotIndicateBreach() throws {
    let suffix = String(repeating: "A", count: 35)
    let padding = String(repeating: "B", count: 35)
    let parsed = try PasswordBreachCheck.parse(Data("\(suffix):12\r\n\(padding):0\r\n".utf8))
    XCTAssertEqual(parsed[suffix], 12)
    XCTAssertNil(parsed[padding])
    for input in ["", "\n\r\n", "not-a-range", "\(suffix):-1", "\(suffix):oops"] {
      XCTAssertThrowsError(try PasswordBreachCheck.parse(Data(input.utf8)))
    }
  }
}
