import XCTest
import CommonRelay
@testable import PasswordVault

/// The common-relay SDK delegates protocol work to vault-core; exercise that bridge end to end.
final class RelayProtocolBridgeTests: XCTestCase {
  private let url = "ws://127.0.0.1:1/relay/v1/ws"
  override func setUp() { super.setUp(); VaultRelay.installCoreProtocol() }

  private func groups(_ device: String) -> RelayGroups {
    RelayGroups(config: ["app": "passwordvault", "url": url, "device": device,
                         "secret_key": RelayIdentity.generateSecretKey().relayHex], allowLocalTest: true)
  }
  private func next(_ entry: [String: Any], _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
    var state = try RelayGroups.unpack(entry)
    state["revision"] = (state["revision"] as? Int ?? 0) + 1
    state["previous"] = RelayGroups.digest(try RelayGroups.payload(entry))
    state["invitation"] = ""; state["request_hash"] = ""
    change(&state)
    return state
  }
  private func members(_ state: [String: Any]) -> [[String: Any]] { state["members"] as? [[String: Any]] ?? [] }

  func testGroupChainSigningAndStrictRulesRunInCore() throws {
    let mac = groups("mac"), phone = groups("phone")
    try mac.prepareCreate(groupName: "Home", deviceName: "Mac")
    let created = try XCTUnwrap(mac.config["pending_create"] as? [String: Any])
    let founder = try XCTUnwrap(members(try RelayGroups.unpack(created)).first)
    XCTAssertEqual(try mac.member(name: "")["signing_key"] as? String, founder["signing_key"] as? String)
    try RelayGroups.verify(created, key: founder["signing_key"] as? String ?? "")
    try mac.accept(created)

    let newcomer = try phone.member(name: "Phone")
    let joined = try mac.sign(try next(created) { s in
      s["members"] = members(s) + [newcomer]
      s["invitation"] = Data(RelayIdentity.generateSecretKey().prefix(16)).relayHex
      s["request_hash"] = RelayIdentity.generateSecretKey().relayHex
    })
    XCTAssertEqual(try mac.advance(created, joined)["signature"] as? String, joined["signature"] as? String)

    // Owner decision: a member's signing_key can never be replaced in place.
    let backfill = try mac.sign(try next(joined) { s in var m = members(s); m[1]["signing_key"] = String(repeating: "11", count: 32); s["members"] = m })
    XCTAssertThrowsError(try mac.advance(joined, backfill))
    let renamed = try mac.sign(try next(joined) { s in var m = members(s); m[1]["name"] = "Pixel"; s["members"] = m })
    _ = try mac.advance(joined, renamed)
    var forged = renamed; forged["signature"] = String(repeating: "00", count: 64)
    XCTAssertThrowsError(try mac.advance(joined, forged))
    let left = try phone.sign(try next(renamed) { s in s["members"] = [founder] })
    _ = try mac.advance(renamed, left)
  }

  func testEnvelopesAndInvitationLinksRunInCore() throws {
    let a = RelayIdentity.generateSecretKey(), b = RelayIdentity.generateSecretKey()
    let aPublic = try RelayIdentity(app: "passwordvault", group: "g", device: "a", secretKey: a, trustedPeers: [:]).publicKey
    let bPublic = try RelayIdentity(app: "passwordvault", group: "g", device: "b", secretKey: b, trustedPeers: [:]).publicKey
    let alice = try RelayIdentity(app: "passwordvault", group: "g", device: "a", secretKey: a, trustedPeers: ["b": bPublic])
    let bob = try RelayIdentity(app: "passwordvault", group: "g", device: "b", secretKey: b, trustedPeers: ["a": aPublic])
    let body = try alice.seal(to: "b", kind: "message", id: "m1", value: ["data": "aGk="])
    XCTAssertEqual(try bob.open(from: "a", kind: "message", id: "m1", body: body)["data"] as? String, "aGk=")
    XCTAssertThrowsError(try bob.open(from: "a", kind: "message", id: "m2", body: body))
    XCTAssertThrowsError(try bob.open(from: "x", kind: "message", id: "m1", body: body))

    let invitation: [String: Any] = ["version": 1, "url": url, "id": Data(RelayIdentity.generateSecretKey().prefix(16)).relayHex]
    let key = RelayIdentity.generateSecretKey()
    let link = try RelayInvitationLinks.make(invitation, key: key, password: "Access-Pass-1")
    let parsed = try RelayInvitationLinks.parse(link, allowLocalTest: true)
    XCTAssertEqual(parsed.url, url); XCTAssertEqual(parsed.id, invitation["id"] as? String)
    XCTAssertEqual(parsed.key, key); XCTAssertEqual(parsed.password, "Access-Pass-1")
    XCTAssertThrowsError(try RelayInvitationLinks.parse(link + "&x", allowLocalTest: true))
    let packet = try RelayInvitationLinks.seal(invitation, key: key, nonce: Data(RelayIdentity.generateSecretKey().prefix(24)))
    XCTAssertEqual(NSDictionary(dictionary: try RelayInvitationLinks.open(packet, key: key)), NSDictionary(dictionary: invitation))
    XCTAssertThrowsError(try RelayInvitationLinks.open(packet, key: RelayIdentity.generateSecretKey()))
    XCTAssertEqual(try RelayInvitationLinks.readToken(key).count, 64)
  }

  func testOwnerRetryPolicyComesFromCore() {
    XCTAssertNil(VaultRelay.retryDelay("group HTTP 401", previous: 4, connected: 0))
    XCTAssertNil(VaultRelay.retryDelay("Group request failed (403)", previous: 4, connected: 0))
    XCTAssertEqual(VaultRelay.retryDelay("timeout", previous: 0, connected: 0), 1)
    XCTAssertEqual(VaultRelay.retryDelay("timeout", previous: 4, connected: 10), 8)
    XCTAssertEqual(VaultRelay.retryDelay("timeout", previous: 30, connected: 120), 1)
  }
}
