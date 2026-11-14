import XCTest
@testable import PasswordVault

#if os(iOS)
typealias RelayTestCore = MobileCore
#else
typealias RelayTestCore = CoreClient
#endif

/// Symmetric sync through the native core without a relay: two replicas exchange
/// packets directly; the newer edit wins and nothing waits for confirmation.
@MainActor
final class SymmetricSyncTests: XCTestCase {
  private func replica(_ device: String, peer: String) async throws -> (RelayTestCore, URL) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("pv-mesh-" + UUID().uuidString)
    let core = try RelayTestCore(directory: path)
    _ = try await core.call(["op": .string("create"), "password": .string("fixture")])
    _ = try await core.call(["op": .string("relay-mesh-init"), "group": .string("fixture-group"), "device": .string(device)])
    _ = try await core.call(["op": .string("relay-mesh-peers"), "peers": .array([.string(peer)])])
    return (core, path)
  }
  private func deliver(_ from: RelayTestCore, _ fromID: String, to: RelayTestCore, _ toID: String) async throws {
    let packet = try await from.call(["op": .string("relay-mesh-export"), "peer": .string(toID)]).object["packet"] ?? .null
    if case .null = packet { return }
    _ = try await to.call(["op": .string("relay-mesh-receive"), "peer": .string(fromID), "packet": packet])
  }
  private func titles(_ core: RelayTestCore) async throws -> [String: String] {
    let items = try await core.call(["op": .string("list")]).object["items"]?.array ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.object["id"]?.string ?? "", $0.object["title"]?.string ?? "") })
  }

  func testBothDirectionsConvergeAndNewestEditWins() async throws {
    let (mac, a) = try await replica("mac", peer: "phone")
    let (phone, b) = try await replica("phone", peer: "mac")
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    _ = try await mac.call(["op": .string("save"), "item": .object(["id": .string("m"), "type": .string("secureNote"), "title": .string("From Mac")])])
    _ = try await phone.call(["op": .string("save"), "item": .object(["id": .string("p"), "type": .string("secureNote"), "title": .string("From phone")])])
    for _ in 0..<3 { try await deliver(mac, "mac", to: phone, "phone"); try await deliver(phone, "phone", to: mac, "mac") }
    let macTitles = try await titles(mac), phoneTitles = try await titles(phone)
    XCTAssertEqual(macTitles, phoneTitles)
    XCTAssertEqual(macTitles["m"], "From Mac"); XCTAssertEqual(macTitles["p"], "From phone")

    _ = try await mac.call(["op": .string("save"), "item": .object(["id": .string("m"), "type": .string("secureNote"), "title": .string("Older Mac edit")])])
    try await Task.sleep(nanoseconds: 5_000_000)
    _ = try await phone.call(["op": .string("save"), "item": .object(["id": .string("m"), "type": .string("secureNote"), "title": .string("Newer phone edit")])])
    for _ in 0..<3 { try await deliver(mac, "mac", to: phone, "phone"); try await deliver(phone, "phone", to: mac, "mac") }
    let macAfter = try await titles(mac), phoneAfter = try await titles(phone)
    XCTAssertEqual(macAfter["m"], "Newer phone edit"); XCTAssertEqual(phoneAfter["m"], "Newer phone edit")
    let status = try await phone.call(["op": .string("relay-status")]).object
    XCTAssertEqual(status["mode"]?.string, "mesh"); XCTAssertEqual(status["pending"]?.number, 0)
  }

  func testPacketsFromOutsideTheRosterAreRejected() async throws {
    let (mac, a) = try await replica("mac", peer: "phone")
    let (phone, b) = try await replica("phone", peer: "mac")
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    _ = try await mac.call(["op": .string("save"), "item": .object(["id": .string("s"), "type": .string("secureNote"), "title": .string("Private")])])
    let packet = try await mac.call(["op": .string("relay-mesh-export"), "peer": .string("phone")]).object["packet"] ?? .null
    do {
      _ = try await phone.call(["op": .string("relay-mesh-receive"), "peer": .string("stranger"), "packet": packet])
      XCTFail("A non-member must be rejected")
    } catch {}
    let phoneTitles = try await titles(phone)
    XCTAssertNil(phoneTitles["s"])
  }
}
