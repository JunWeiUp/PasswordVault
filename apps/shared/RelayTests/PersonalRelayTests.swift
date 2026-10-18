import XCTest
import CryptoKit
import CommonRelay
@testable import PasswordVault

#if os(iOS)
typealias RelayTestCore = MobileCore
#else
typealias RelayTestCore = CoreClient
#endif

@MainActor
final class PersonalRelayTests: XCTestCase {
  private func fixture(role: String) async throws -> (RelayTestCore, VaultRelay, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pv-relay-test-" + UUID().uuidString)
    let core = try RelayTestCore(directory: directory)
    _ = try await core.call(["op": .string("create"), "password": .string("fixture")])
    let relay = VaultRelay(directory: directory, role: role, call: { try await core.call($0) }, refresh: {}, credentialReader: { _, _ in nil })
    relay.setUnlocked(true)
    for _ in 0..<100 where !relay.credentialsReady { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertTrue(relay.credentialsReady)
    return (core, relay, directory)
  }
  private func credential(_ relay: VaultRelay, group: String, device: String, token: String = String(repeating: "a", count: 64)) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["identity": ["app":"passwordvault", "group":group, "device":device, "public_key":relay.publicKey], "token":token]), as: UTF8.self)
  }
  func testExplicitPairingPinsKeysAndRejectsChallengeReplay() async throws {
    let (mac, hub, a) = try await fixture(role: "hub")
    let (_, mobile, b) = try await fixture(role: "mobile")
    defer { hub.setUnlocked(false); mobile.setUnlocked(false); try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let group = "fixture"
    await hub.importCredential(try credential(hub, group: group, device: "mac"), endpoint: "wss://relay.example.test/relay/v1/ws")
    await mobile.importCredential(try credential(mobile, group: group, device: "phone"), endpoint: "wss://relay.example.test/relay/v1/ws")
    XCTAssertNil(hub.failure); XCTAssertNil(mobile.failure)
    await hub.invite(); await mobile.pair(hub.pairingText)
    XCTAssertNil(mobile.failure)
    let reply = mobile.pairingText
    XCTAssertEqual(hub.previewCode(reply), mobile.verificationCode)
    let before = try await mac.call(["op":.string("relay-status")])
    XCTAssertEqual(before.object["peers"]?.array.count, 0)
    await hub.pair(reply); XCTAssertNil(hub.failure)
    let after = try await mac.call(["op":.string("relay-status")])
    XCTAssertEqual(after.object["peers"]?.array.count, 1)
    await hub.pair(reply); XCTAssertNotNil(hub.failure)
    await hub.revoke("phone")
    let revoked = try await mac.call(["op":.string("relay-status")])
    XCTAssertEqual(revoked.object["peers"]?.array.count, 0)
  }
  func testCredentialForAnotherPublicKeyIsRejected() async throws {
    let (_, relay, directory) = try await fixture(role: "hub")
    defer { try? FileManager.default.removeItem(at: directory) }
    let text = try credential(relay, group: "fixture", device: "mac").replacingOccurrences(of: relay.publicKey, with: String(repeating: "0", count: 64))
    await relay.importCredential(text, endpoint: "wss://relay.example.test/relay/v1/ws")
    XCTAssertNotNil(relay.failure); XCTAssertTrue(relay.config.token.isEmpty)
  }
  func testProductionWSSWithIsolatedFixtures() async throws {
    guard let path = ProcessInfo.processInfo.environment["PV_RELAY_QA_CONFIG"] else { throw XCTSkip("Provide isolated QA credentials explicitly") }
    let configs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:path))) as! [[String:Any]]
    let (mac, hub, a) = try await fixture(role: "hub")
    let (phone, mobile, b) = try await fixture(role: "mobile")
    defer { hub.setUnlocked(false); mobile.setUnlocked(false); try? FileManager.default.removeItem(at:a); try? FileManager.default.removeItem(at:b) }
    for (relay,c) in [(hub,configs[0]),(mobile,configs[1])] {
      relay.config.secret = try Data(relayHex:c["secret_key"] as! String)
      await relay.importCredential(try credential(relay,group:c["group"] as! String,device:c["device"] as! String,token:c["token"] as! String),endpoint:c["url"] as! String)
      XCTAssertNil(relay.failure)
    }
    await hub.invite();await mobile.pair(hub.pairingText);await hub.pair(mobile.pairingText)
    XCTAssertNil(hub.failure);XCTAssertNil(mobile.failure)
    hub.setUnlocked(true);mobile.setUnlocked(true)
    _ = try await phone.call(["op":.string("save"),"item":.object(["id":.string("from-phone"),"type":.string("password"),"title":.string("WSS fixture")])])
    try await eventually { try await mac.document().items.contains { $0.id == "from-phone" } }
    let large = String(repeating:"Synthetic relay file. ",count:15000)
    _ = try await mac.call(["op":.string("save"),"item":.object(["id":.string("large"),"type":.string("secureNote"),"title":.string("Large fixture"),"note":.string(large)])])
    try await eventually { try await phone.document().items.contains { $0.id == "large" && $0.string("note") == large } }
    mobile.setUnlocked(false)
    _ = try await mac.call(["op":.string("save"),"item":.object(["id":.string("offline"),"type":.string("secureNote"),"title":.string("Offline fixture")])])
    try await Task.sleep(nanoseconds:7_000_000_000)
    mobile.setUnlocked(true)
    try await eventually { try await phone.document().items.contains { $0.id == "offline" } }
  }
  func testAndroidWSSInterop() async throws {
    guard let path=ProcessInfo.processInfo.environment["PV_RELAY_ANDROID_QA_CONFIG"] else { throw XCTSkip("Explicit Android interop fixture required") }
    let configs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [[String:Any]]
    let (mac,hub,directory)=try await fixture(role:"hub")
    defer {hub.setUnlocked(false);try? FileManager.default.removeItem(at:directory)}
    let c=configs[0], p=configs[1]
    hub.config.secret=try Data(relayHex:c["secret_key"] as! String)
    await hub.importCredential(try credential(hub,group:c["group"] as! String,device:c["device"] as! String,token:c["token"] as! String),endpoint:c["url"] as! String)
    XCTAssertNil(hub.failure)
    hub.config.peers[p["device"] as! String]=p["public_key"] as? String
    _=try await mac.call(["op":.string("relay-trust"),"peer":.string(p["device"] as! String)])
    await hub.setPaused(false)
    _=try await mac.call(["op":.string("save"),"item":.object(["id":.string("android-large"),"type":.string("secureNote"),"title":.string("Mac to Android"),"note":.string(String(repeating:"INTEROP",count:45000))])])
    var received=false
    for _ in 0..<180 {
      if try await mac.document().items.contains(where:{$0.id=="android-roundtrip"}) {received=true;break}
      try await Task.sleep(nanoseconds:1_000_000_000)
    }
    XCTAssertTrue(received,"Android reply did not commit on Mac")
    _=try await mac.call(["op":.string("save"),"item":.object(["id":.string("android-ack"),"type":.string("secureNote"),"title":.string("Roundtrip complete")])])
    try await Task.sleep(nanoseconds:15_000_000_000)
  }
  #if os(iOS)
  func testIOSWSSReplica() async throws {
    guard let path=ProcessInfo.processInfo.environment["PV_RELAY_IOS_QA_CONFIG"] else {throw XCTSkip("Explicit iOS WSS fixture required")}
    let configs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [[String:Any]]
    let (phone,mobile,directory)=try await fixture(role:"mobile")
    defer {mobile.setUnlocked(false);try? FileManager.default.removeItem(at:directory)}
    let c=configs[1],hub=configs[0]
    mobile.config.secret=try Data(relayHex:c["secret_key"] as! String)
    await mobile.importCredential(try credential(mobile,group:c["group"] as! String,device:c["device"] as! String,token:c["token"] as! String),endpoint:c["url"] as! String)
    XCTAssertNil(mobile.failure)
    mobile.config.hub=hub["device"] as! String
    mobile.config.peers[hub["device"] as! String]=hub["public_key"] as? String
    _=try await phone.call(["op":.string("relay-init"),"role":.string("mobile"),"group":.string(c["group"] as! String),"device":.string(c["device"] as! String),"hub":.string(hub["device"] as! String)])
    _=try await phone.call(["op":.string("relay-trust"),"peer":.string(hub["device"] as! String)])
    await mobile.setPaused(false)
    try await eventually {try await phone.document().items.contains{$0.id=="android-large" && $0.string("note").count==315000}}
    _=try await phone.call(["op":.string("save"),"item":.object(["id":.string("android-roundtrip"),"type":.string("secureNote"),"title":.string("iOS to Mac")])])
    try await eventually {try await phone.document().items.contains{$0.id=="android-ack"}}
    XCTAssertNotNil(mobile.lastSuccess)
  }
  #endif
  private func eventually(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<60 { if try await predicate() { return }; try await Task.sleep(nanoseconds:1_000_000_000) }
    XCTFail("Relay business commit timed out")
  }
}
