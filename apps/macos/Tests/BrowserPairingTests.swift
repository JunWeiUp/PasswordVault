import XCTest

@testable import PasswordVault

final class BrowserPairingTests: XCTestCase {
  func testMultipleBrowsersPreserveLegacyTokenAndRotateOnlyTheirOwnConnection() throws {
    let id = "fixture-extension"
    let original: [String: JSONValue] = [
      "theme": .string("light"), "browserPairings": .object([id: .string("legacy-browser-token")]),
    ]
    let edge = try NativeBrowserBridge.addingPairing(
      extensionID: id, previousToken: "", newToken: "edge-token", settings: original)
    let both = try NativeBrowserBridge.addingPairing(
      extensionID: id, previousToken: "", newToken: "ego-token", settings: edge)
    for token in ["legacy-browser-token", "edge-token", "ego-token"] {
      XCTAssertTrue(NativeBrowserBridge.isPaired(extensionID: id, token: token, settings: both))
    }
    XCTAssertEqual(NativeBrowserBridge.pairingCount(settings: both), 3)
    let rotated = try NativeBrowserBridge.addingPairing(
      extensionID: id, previousToken: "edge-token", newToken: "edge-replacement", settings: both)
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(extensionID: id, token: "edge-token", settings: rotated))
    for token in ["legacy-browser-token", "edge-replacement", "ego-token"] {
      XCTAssertTrue(NativeBrowserBridge.isPaired(extensionID: id, token: token, settings: rotated))
    }
    XCTAssertEqual(rotated["theme"], .string("light"))
    XCTAssertEqual(NativeBrowserBridge.pairingCount(settings: rotated), 3)
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(extensionID: "other", token: "ego-token", settings: rotated))
  }

  func testMultiplePairingsPersistAndCanAllBeRevoked() throws {
    let settings = try NativeBrowserBridge.addingPairing(
      extensionID: "fixture", previousToken: "", newToken: "second",
      settings: ["browserPairings": .object(["fixture": .string("first")])])
    var restored = try JSONDecoder().decode(
      [String: JSONValue].self, from: JSONEncoder().encode(settings))
    XCTAssertTrue(
      NativeBrowserBridge.isPaired(extensionID: "fixture", token: "first", settings: restored))
    XCTAssertTrue(
      NativeBrowserBridge.isPaired(extensionID: "fixture", token: "second", settings: restored))
    restored["browserPairings"] = .object([:])
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(extensionID: "fixture", token: "first", settings: restored))
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(extensionID: "fixture", token: "second", settings: restored))
  }

  func testFullPairingCapacityDoesNotEvictExistingBrowsers() throws {
    let settings: [String: JSONValue] = [
      "browserPairings": .object(["fixture": .array((0..<64).map { .string("token-\($0)") })])
    ]
    XCTAssertThrowsError(
      try NativeBrowserBridge.addingPairing(
        extensionID: "fixture", previousToken: "", newToken: "new", settings: settings))
    XCTAssertEqual(NativeBrowserBridge.pairingCount(settings: settings), 64)
    let rotated = try NativeBrowserBridge.addingPairing(
      extensionID: "fixture", previousToken: "token-0", newToken: "replacement", settings: settings)
    XCTAssertEqual(NativeBrowserBridge.pairingCount(settings: rotated), 64)
    XCTAssertTrue(
      NativeBrowserBridge.isPaired(extensionID: "fixture", token: "token-63", settings: rotated))
  }

  func testCapturePreservesWebsitePort() {
    XCTAssertEqual(
      NativeBrowserBridge.websiteOrigin("https://example.test:8443/")?.absoluteString,
      "https://example.test:8443")
    XCTAssertEqual(
      NativeBrowserBridge.websiteOrigin("http://localhost:8080")?.absoluteString,
      "http://localhost:8080")
  }

  func testCaptureRejectsNonOriginURLs() {
    for value in [
      "file:///tmp/example", "https://user:password@example.test", "https://example.test/login",
      "https://example.test?query=1", "https://example.test#fragment", "https://example.test:70000",
    ] {
      XCTAssertNil(NativeBrowserBridge.websiteOrigin(value))
    }
  }

  func testPairingStatusRejectsMissingRevokedAndOtherExtensionTokens() {
    let identity = "fixture-extension"
    let token = "A synthetic capability with random-looking bytes"
    let settings: [String: JSONValue] = ["browserPairings": .object([identity: .string(token)])]
    XCTAssertTrue(
      NativeBrowserBridge.isPaired(extensionID: identity, token: token, settings: settings))
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(extensionID: identity, token: "", settings: settings))
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(extensionID: identity, token: token + "x", settings: settings))
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(
        extensionID: identity, token: String(token.dropLast()) + "X", settings: settings))
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(
        extensionID: "another-extension", token: token, settings: settings))
    XCTAssertFalse(NativeBrowserBridge.isPaired(extensionID: identity, token: token, settings: [:]))
    XCTAssertFalse(
      NativeBrowserBridge.isPaired(
        extensionID: identity, token: "",
        settings: ["browserPairings": .object([identity: .string("")])]))
  }
}
