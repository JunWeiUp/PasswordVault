import Foundation

/// A single explicitly enrolled library. The transport must authenticate `from` and
/// encrypt payloads to its pinned public key; device-group membership is insufficient.
@MainActor
final class PeerLibrarySync {
  typealias Command = ([String: JSONValue]) async throws -> JSONValue
  typealias Delivery = (String, String, Data) async throws -> Void
  private let command: Command
  private let deliver: Delivery
  private(set) var library: String
  private let device: String
  private var appliedDigests: [String: Data] = [:]

  init(library: String, device: String, command: @escaping Command, deliver: @escaping Delivery) {
    self.library = library; self.device = device; self.command = command; self.deliver = deliver
  }

  func status() async throws -> [String: JSONValue] {
    try await command(["op": .string("relay-peer-status"), "library": .string(library)]).object
  }

  /// Sends only to members authorized by the signed library control chain, never
  /// to all members returned by a relay's group discovery API.
  func synchronize() async throws {
    let state = try await status()
    guard state["frozen"]?.bool != true else { throw PeerSyncError.authorization }
    for (peer, value) in state["members"]?.object ?? [:] where peer != device {
      guard let key = value.object["transportKey"]?.string, !key.isEmpty else { continue }
      let packet = try await command(["op": .string("relay-peer-export"), "library": .string(library), "peer": .string(peer)])
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(packet)
      guard appliedDigests[peer] != data else { continue }
      try await deliver(peer, key, data)
      // This is a transport delivery cache, NOT an acknowledgement that the remote
      // vault committed it. resetDeliveryCache() reconciles on reconnect/resume.
      appliedDigests[peer] = data
    }
  }

  func receive(_ data: Data, from: String, authenticatedTransportKey: String) async throws {
    let state = try await status()
    guard state["frozen"]?.bool != true,
      let member = state["members"]?.object[from],
      member.object["transportKey"]?.string == authenticatedTransportKey,
      !authenticatedTransportKey.isEmpty else { throw PeerSyncError.authorization }
    let envelope = try JSONDecoder().decode(JSONValue.self, from: data)
    _ = try await command(["op": .string("relay-peer-receive"), "library": .string(library), "envelope": envelope])
  }

  func resolve(key: String, value: JSONValue) async throws {
    _ = try await command(["op": .string("relay-peer-resolve"), "library": .string(library), "key": .string(key), "value": value])
    resetDeliveryCache()
  }

  func authorize(device: String, signingKey: String, transportKey: String, role: String) async throws {
    guard ["admin", "editor", "reader"].contains(role), !transportKey.isEmpty else { throw PeerSyncError.authorization }
    _ = try await command(["op": .string("relay-peer-authorize"), "library": .string(library), "peer": .string(device),
                          "member": .object(["publicKey": .string(signingKey), "transportKey": .string(transportKey), "role": .string(role)])])
    resetDeliveryCache()
  }

  func revoke(device: String) async throws {
    _ = try await command(["op": .string("relay-peer-authorize"), "library": .string(library), "peer": .string(device), "member": .null])
    resetDeliveryCache()
  }

  func resetDeliveryCache() { appliedDigests.removeAll() }
  enum PeerSyncError: Error { case authorization }
}
