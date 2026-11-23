import XCTest
@testable import PasswordVault

/// The relay stack (protocol, groups, WSS, files, journal) lives in vault-core; exercise its Swift binding.
final class RelayCoreTests: XCTestCase {
  func testOwnerRetryPolicyAndLinksComeFromCore() throws {
    XCTAssertNil(VaultRelay.retryDelay("RelayHttp401", previous: 4, connected: 0))
    XCTAssertEqual(VaultRelay.retryDelay("RelayConnection", previous: 4, connected: 10), 8)
    XCTAssertEqual(VaultRelay.retryDelay("RelayConnection", previous: 30, connected: 120), 1)
    let invitation: [String: Any] = ["version": 1, "url": "wss://relay.example/relay/v1/ws", "id": String(repeating: "ab", count: 16)]
    let key = RelayIdentity.generateSecretKey()
    let link = try RelayInvitationLinks.make(invitation, key: key, password: "fixture-access-123")
    let parsed = try RelayInvitationLinks.parse(link)
    XCTAssertEqual(parsed.url, "wss://relay.example/relay/v1/ws"); XCTAssertEqual(parsed.key, key)
    XCTAssertEqual(parsed.password, "fixture-access-123")
    XCTAssertThrowsError(try RelayInvitationLinks.parse(link + "&x"))
    XCTAssertEqual(try RelayCodec.publicKey(secret: key).count, 64)
  }

  /// Two in-process devices over a real Common Relay (`PV_GROUP_TEST_URL=ws://127.0.0.1:PORT/v2/ws`).
  func testGroupMessagesAndFilesOverALiveRelay() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["PV_GROUP_TEST_URL"], url.hasPrefix("ws://127.0.0.1:"), let password = env["PV_GROUP_TEST_PASSWORD"] else {
      throw XCTSkip("PV_GROUP_TEST_URL/PV_GROUP_TEST_PASSWORD not set")
    }
    func device() -> [String: Any] {
      ["app": "passwordvault", "url": url, "device": UUID().uuidString.lowercased(),
       "secret_key": RelayIdentity.generateSecretKey().relayHex, "password": password]
    }
    let mac = CoreGroups(config: device(), allowLocal: true) { _ in }
    try await mac.create(name: "Home", deviceName: "Mac")
    let link = try await mac.invite(automatic: true)
    let phone = CoreGroups(config: device(), allowLocal: true) { _ in }
    let joined = try await phone.join(try await phone.resolveInvitation(link, passwordOverride: nil), name: "Phone")
    XCTAssertTrue(joined)
    let state = try await mac.refresh()["state"] as? [String: Any]
    XCTAssertEqual((state?["members"] as? [Any])?.count, 2)

    let journal = FileManager.default.temporaryDirectory.appendingPathComponent("pv-relay-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: journal) }
    func options(_ g: CoreGroups, _ name: String) throws -> String {
      try RelayCodec.options(url: url, token: g.config["token"] as! String, password: password, group: g.config["group"] as! String,
                             device: g.config["device"] as! String, secret: try Data(relayHex: g.config["secret_key"] as! String),
                             trusted: g.config["trusted_peers"] as? [String: String] ?? [:], journal: journal.appendingPathComponent(name), allowLocal: true)
    }
    let macID = mac.config["device"] as! String, phoneID = phone.config["device"] as! String
    let a = try await CoreRelayConnection.connect(options: try options(mac, "a"))
    let b = try await CoreRelayConnection.connect(options: try options(phone, "b"))
    let peers = try await a.peers()
    XCTAssertTrue(peers.contains { $0.device == phoneID })
    try await a.message(to: phoneID, data: Data("hello".utf8), offline: true, id: String(repeating: "0a", count: 16))
    var received: [String: Any]?
    for try await event in b.events() where event["type"] as? String == "message" { received = event; break }
    XCTAssertEqual(received?["data"] as? Data, Data("hello".utf8))
    try await b.acknowledge(id: received?["id"] as! String, from: macID, offline: received?["offline"] as? Bool ?? false)

    let files = try CoreRelayFiles(options: try options(mac, "fa")), inbox = try CoreRelayFiles(options: try options(phone, "fb"))
    let payload = Data(repeating: 9, count: 200_000)
    try await files.send(to: phoneID, data: payload)
    let pending = try await inbox.inbox()
    XCTAssertEqual(pending.count, 1)
    let bytes = try await inbox.receive(pending[0])
    XCTAssertEqual(bytes, payload)
    try await inbox.acknowledge(id: pending[0]["id"] as! String)
    await a.close(); await b.close()

    try await phone.exit(disband: false)
    let after = try await mac.refresh()["state"] as? [String: Any]
    XCTAssertEqual((after?["members"] as? [Any])?.count, 1)
    var wrong = try RelayCodec.json(try options(mac, "w")); wrong["password"] = "wrong-relay-access"
    do { _ = try await CoreRelayConnection.connect(options: try RelayCodec.text(wrong)); XCTFail("expected 401") }
    catch { XCTAssertNil(VaultRelay.retryDelay(RelayCodec.code(error), previous: 1, connected: 0)) }
  }
}
