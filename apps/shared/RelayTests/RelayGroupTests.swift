import XCTest
import CommonRelay
@testable import PasswordVault

@MainActor
final class RelayGroupTests: XCTestCase {
  private func fixture(_ role: String) async throws -> (RelayTestCore, VaultRelay, URL) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("pv-groups-" + UUID().uuidString)
    let core = try RelayTestCore(directory: path)
    _ = try await core.call(["op": .string("create"), "password": .string("fixture")])
    let relay = VaultRelay(directory: path, role: role, allowLocalGroupTest: true, call: { try await core.call($0) }, refresh: {})
    relay.setUnlocked(true)
    return (core, relay, path)
  }
  private func server() throws -> String {
    guard let url = ProcessInfo.processInfo.environment["PV_GROUP_TEST_URL"], url.hasPrefix("ws://127.0.0.1:") else {
      throw XCTSkip("Requires a disposable local relay with self-service-apps=passwordvault")
    }
    return url
  }
  func testSignedMembershipRejectsTamperingRollbackAndUnauthorizedChanges() throws {
    let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "group-vectors", withExtension: "json"))
    let v = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let groups = RelayGroups(config: v["config"] as! [String: Any])
    let first = v["initial"] as! [String: Any], added = v["approved"] as! [String: Any], removed = v["removed"] as! [String: Any]
    _ = try groups.advance(first, added); _ = try groups.advance(added, removed)
    _ = try groups.advance(added, v["renamed"] as! [String: Any])
    _ = try groups.advance(added, v["left"] as! [String: Any])
    _ = try groups.advance(added, v["disbanded"] as! [String: Any])
    let auto = v["auto_admission"] as! [String: Any]
    _ = try groups.advance(first, auto["approved"] as! [String: Any])
    for invalid in auto["invalid"] as! [[String: Any]] {
      XCTAssertThrowsError(try groups.advance(first, invalid["entry"] as! [String: Any]))
    }
    XCTAssertThrowsError(try groups.advance(first, removed))
    XCTAssertThrowsError(try groups.advance(added, v["unauthorized_rename"] as! [String: Any]))
    XCTAssertThrowsError(try groups.advance(added, v["unauthorized_disband"] as! [String: Any]))
    var tampered = added; tampered["signature"] = String(repeating: "0", count: 128)
    XCTAssertThrowsError(try groups.advance(first, tampered))
  }
  func testCreateJoinApprovalRevocationAndExitKeepVaultAuthoritySeparate() async throws {
    let url = try server()
    let (core, mac, a) = try await fixture("hub")
    let (phoneCore, phone, b) = try await fixture("mobile")
    defer { mac.setUnlocked(false); phone.setUnlocked(false); try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    await mac.createGroup(endpoint: url, name: "Fictional group", deviceName: "Fixture Mac")
    XCTAssertNil(mac.failure); XCTAssertTrue(mac.groupManager)
    await mac.inviteToGroup(automatic: false); XCTAssertFalse(mac.groupInvite.isEmpty)
    await phone.joinGroup(mac.groupInvite, deviceName: "Fixture phone")
    XCTAssertNil(phone.failure); XCTAssertTrue(phone.joiningGroup)
    let draft = phone.config.groupState
    await phone.retryGroupJoin(); XCTAssertEqual(draft, phone.config.groupState)
    await mac.checkGroupRequest(); XCTAssertEqual(mac.groupCode, phone.groupCode)
    XCTAssertEqual(mac.applicantName, "Fixture phone")
    XCTAssertTrue(mac.config.peers.isEmpty)
    await mac.approveGroupRequest(manager: false); XCTAssertNil(mac.failure)
    await phone.finishGroupJoin(); XCTAssertNil(phone.failure)
    XCTAssertTrue(phone.hasManagedGroup); XCTAssertFalse(phone.groupManager)
    let state = try await core.call(["op": .string("relay-status")])
    XCTAssertEqual(state.object["enabled"]?.bool, false)
    XCTAssertTrue(phone.config.peers.isEmpty)
    await phone.inviteToGroup(); XCTAssertNotNil(phone.failure)
    await mac.leaveGroup(disband: false); XCTAssertNotNil(mac.failure) // Last manager cannot abandon another member.
    await mac.refreshGroup(); XCTAssertNil(mac.failure)
    await mac.renameGroupMember(phone.config.device, name: "Renamed fixture")
    XCTAssertNil(mac.failure); XCTAssertTrue(mac.groupMembers.contains { $0.name == "Renamed fixture" })
    // Only explicit vault pairing enables transfer; the welcome group revision
    // must not force endless reconnects before the first commit.
    await mac.invite(); await phone.pair(mac.pairingText)
    XCTAssertEqual(mac.previewCode(phone.pairingText), phone.verificationCode)
    await mac.pair(phone.pairingText); XCTAssertNil(mac.failure)
    _ = try await phoneCore.call(["op": .string("save"), "item": .object(["id": .string("synced"), "type": .string("secureNote"), "title": .string("Managed group transfer")])])
    var transferred = false
    for _ in 0..<150 {
      let list = try await core.call(["op": .string("list")])
      if list.object["items"]?.array.contains(where: { $0.object["id"]?.string == "synced" }) == true { transferred = true; break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(transferred, "Managed transport should deliver after the initial group.changed event")
    for _ in 0..<150 where mac.groupBusy || phone.groupBusy { try await Task.sleep(nanoseconds: 100_000_000) }
    // Removing group membership also removes local vault trust before reconnect.
    await mac.removeGroupMember(phone.config.device); XCTAssertNil(mac.failure)
    XCTAssertTrue(mac.config.peers.isEmpty)
    for _ in 0..<150 where phone.groupBusy { try await Task.sleep(nanoseconds: 100_000_000) }
    await phone.refreshGroup(); XCTAssertTrue(phone.groupInvalid); XCTAssertTrue(phone.groupMembers.isEmpty)
    let original = phone.config.device, secret = phone.config.secret
    _ = try await phoneCore.call(["op": .string("save"), "item": .object(["id": .string("local"), "type": .string("secureNote"), "title": .string("Local fixture")])])
    await phone.clearLocalGroup(); XCTAssertNil(phone.failure)
    XCTAssertNotEqual(phone.config.device, original); XCTAssertEqual(phone.config.secret, secret)
    let retained = try await phoneCore.call(["op": .string("list")])
    XCTAssertTrue(retained.object["items"]?.array.contains { $0.object["id"]?.string == "local" } == true)
    await mac.leaveGroup(disband: false); XCTAssertNil(mac.failure); XCTAssertFalse(mac.hasManagedGroup)
  }
  func testMobileCanCreateAndManageGroupAndDisbandInvalidatesOtherMembers() async throws {
    let url = try server()
    let (_, phone, a) = try await fixture("mobile")
    let (_, mac, b) = try await fixture("hub")
    defer { phone.setUnlocked(false); mac.setUnlocked(false); try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    await phone.createGroup(endpoint: url, name: "Phone managed", deviceName: "Phone")
    await phone.inviteToGroup(automatic: false); await mac.joinGroup(phone.groupInvite, deviceName: "Mac")
    await phone.checkGroupRequest(); await phone.approveGroupRequest(manager: true); await mac.finishGroupJoin()
    XCTAssertNil(mac.failure); XCTAssertTrue(mac.groupManager)
    XCTAssertEqual(mac.config.hub, mac.config.device)
    await phone.leaveGroup(disband: true); XCTAssertNil(phone.failure)
    await mac.refreshGroup(); XCTAssertTrue(mac.groupInvalid); XCTAssertFalse(mac.groupManager)
    XCTAssertTrue(mac.groupInvite.isEmpty); XCTAssertTrue(mac.groupMembers.isEmpty)
  }
  func testDefaultAutomaticShortInvitationJoinsWithoutVaultAuthorization() async throws {
    let url = try server()
    let (core, mac, a) = try await fixture("hub")
    let (_, phone, b) = try await fixture("mobile")
    defer { mac.setUnlocked(false); phone.setUnlocked(false); try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    await mac.createGroup(endpoint: url, name: "Auto fixture", deviceName: "Mac")
    await mac.inviteToGroup()
    XCTAssertNil(mac.failure); XCTAssertTrue(mac.automaticGroupJoin)
    XCTAssertTrue(mac.groupInvite.hasPrefix("common-relay:")); XCTAssertLessThan(mac.groupInvite.count, 200)
    await phone.joinGroup(mac.groupInvite, deviceName: "Phone")
    XCTAssertNil(phone.failure); XCTAssertTrue(phone.hasManagedGroup); XCTAssertFalse(phone.joiningGroup)
    XCTAssertFalse(phone.groupManager); XCTAssertTrue(phone.config.peers.isEmpty)
    await mac.refreshGroup()
    XCTAssertNil(mac.failure); XCTAssertEqual(mac.groupMembers.count, 2); XCTAssertTrue(mac.config.peers.isEmpty)
    let state = try await core.call(["op": .string("relay-status")])
    XCTAssertEqual(state.object["enabled"]?.bool, false)
    await mac.leaveGroup(disband: true)
    XCTAssertNil(mac.failure)
  }
  func testJoinDraftIsSavedBeforeNetworkFailureAndSurvivesRestart() async throws {
    let (_, phone, path) = try await fixture("mobile")
    defer { phone.setUnlocked(false); try? FileManager.default.removeItem(at: path) }
    let inv: [String: Any] = ["version": 1, "app": "passwordvault", "group": "fixture", "url": "ws://127.0.0.1:1/relay/v1/ws",
                              "expires": Date().timeIntervalSince1970 + 600, "id": "fixture", "secret": "fixture", "manager": [:]]
    await phone.joinGroup(String(decoding: try JSONSerialization.data(withJSONObject: inv), as: UTF8.self), deviceName: "Phone")
    XCTAssertNotNil(phone.failure); XCTAssertTrue(phone.joiningGroup); XCTAssertFalse(phone.groupCode.isEmpty)
    let old = phone.config.groupState
    let reloaded = VaultRelay(directory: path, role: "mobile", allowLocalGroupTest: true, call: { _ in .null }, refresh: {})
    XCTAssertEqual(reloaded.config.groupState, old); XCTAssertEqual(reloaded.groupCode, phone.groupCode)
    XCTAssertTrue(reloaded.config.token.isEmpty); XCTAssertTrue(reloaded.config.peers.isEmpty)
  }
}
