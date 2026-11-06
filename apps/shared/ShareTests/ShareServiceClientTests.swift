import XCTest

@testable import PasswordVault

final class ShareServiceClientTests: XCTestCase {
  func testCreationNeverTransmitsKeyAndDoesNotTrustReturnedURL() async throws {
    let id = String(repeating: "a", count: 32)
    let key = String(repeating: "A", count: 43)
    let client = try ShareServiceClient(
      endpoint: "https://share.example.test", token: String(repeating: "t", count: 40)
    ) { request in
      XCTAssertEqual(request.url?.absoluteString, "https://share.example.test/api/shares")
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      XCTAssertNil(body["key"])
      XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains(key))
      XCTAssertEqual(body["expiresIn"] as? Int, 604800)
      let data = try JSONSerialization.data(withJSONObject: [
        "id": id, "url": "https://untrusted.example/",
      ])
      return (
        data,
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
      )
    }
    let link = try await client.create(
      .object([
        "version": .number(1), "id": .string(id), "key": .string(key), "nonce": .string("fixture"),
        "ciphertext": .string("encrypted fixture"),
      ]), expiresIn: 604800, email: nil)
    XCTAssertEqual(link, "https://share.example.test/s/" + id + "#" + key)
  }
  func testInvalidEndpointAndRedirectResponseAreRejected() async throws {
    for endpoint in [
      "http://remote.example", "https://user:fixture@example.test", "https://example.test/path",
      "https://example.test/#fragment",
    ] {
      XCTAssertThrowsError(
        try ShareServiceClient(endpoint: endpoint, token: String(repeating: "t", count: 40)))
    }
    let client = try ShareServiceClient(
      endpoint: "https://share.example.test", token: String(repeating: "t", count: 40)
    ) { request in
      (
        Data(),
        HTTPURLResponse(
          url: request.url!, statusCode: 302, httpVersion: nil,
          headerFields: ["Location": "https://untrusted.example/"])!
      )
    }
    do {
      _ = try await client.capabilities()
      XCTFail("Redirect accepted")
    } catch {}
  }
}
