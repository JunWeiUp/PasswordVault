import Foundation
import CryptoKit

// Thin Swift adapter over vault-core's relay implementation (protocol, group state machine,
// WSS connection, files, journal). Core calls block, so they run on detached tasks/threads.

/// App-level relay failures (core failures arrive as `RelayError.Failed(code:)`).
enum RelayFault: Error, LocalizedError {
  case invalid(String), closed
  var errorDescription: String? {
    switch self { case .invalid(let message): return message; case .closed: return "closed" }
  }
}

extension Data {
  init(relayHex: String) throws {
    guard relayHex.count % 2 == 0 else { throw RelayFault.invalid("hex") }
    var bytes = Data(capacity: relayHex.count / 2); var index = relayHex.startIndex
    while index < relayHex.endIndex {
      let next = relayHex.index(index, offsetBy: 2)
      guard let byte = UInt8(relayHex[index..<next], radix: 16) else { throw RelayFault.invalid("hex") }
      bytes.append(byte); index = next
    }
    self = bytes
  }
  var relayHex: String { map { String(format: "%02x", $0) }.joined() }
}

enum RelayIdentity {
  static func generateSecretKey() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
    return Data(bytes)
  }
}

struct RelayPeer { let app: String, group: String, device: String }

enum RelayCodec {
  static func json(_ text: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw RelayFault.invalid("json") }
    return value
  }
  static func text(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
  }
  static func call(_ request: [String: JSONValue]) throws -> [String: Any] {
    let data = try JSONEncoder().encode(request)
    return try json(try relayProtocol(request: String(decoding: data, as: UTF8.self)))
  }
  /// Envelope (X25519) public key for a transport secret.
  static func publicKey(secret: Data) throws -> String {
    guard let key = try call(CoreRequest.relayProtocolKeys(secret: secret.relayHex))["publicKey"] as? String else { throw RelayFault.invalid("key") }
    return key
  }
  /// Strictly parsed state of a signed group entry.
  static func unpack(_ entry: [String: Any]) throws -> [String: Any] {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(try text(entry).utf8))
    guard let state = try call(CoreRequest.relayProtocolUnpack(entry: value))["state"] as? [String: Any] else { throw RelayFault.invalid("entry") }
    return state
  }
  static func value(_ object: Any) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(try text(object).utf8))
  }
  /// Verifies `entry` as the next signed group state after `current` (strict chain rules).
  @discardableResult
  static func advance(_ current: [String: Any], _ entry: [String: Any]) throws -> [String: Any] {
    guard let next = try call(CoreRequest.relayProtocolAdvance(current: try value(current), entry: try value(entry)))["entry"] as? [String: Any]
    else { throw RelayFault.invalid("entry") }
    return next
  }
  static func payload(_ entry: [String: Any]) throws -> Data {
    guard let text = entry["payload"] as? String, let raw = Data(base64Encoded: text) else { throw RelayFault.invalid("payload") }
    return raw
  }
  static func digest(_ data: Data) -> String { Data(SHA256.hash(data: data)).relayHex }
  /// `{url, token, password?, allowLocal, identity, journal?}` for connections and file clients.
  static func options(url: String, token: String, password: String?, group: String, device: String, secret: Data,
                      trusted: [String: String], journal: URL?, allowLocal: Bool) throws -> String {
    var value: [String: Any] = ["url": url, "token": token, "allowLocal": allowLocal,
      "identity": ["app": "passwordvault", "group": group, "device": device, "secret": secret.relayHex, "trusted": trusted]]
    if let password, !password.isEmpty { value["password"] = password }
    if let journal { value["journal"] = journal.path }
    return try text(value)
  }
  /// Core relay error code (`RelayHttp401`, ...) for the shared retry policy.
  static func code(_ error: Error) -> String {
    if case RelayError.Failed(let code) = error { return code }
    return String(describing: error)
  }
}

private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
  try await Task.detached(priority: .utility) { try work() }.value
}

/// One WSS connection (vault-core `RelayConnection`).
final class CoreRelayConnection: @unchecked Sendable {
  let inner: RelayConnection
  private init(_ inner: RelayConnection) { self.inner = inner }
  static func connect(options: String) async throws -> CoreRelayConnection {
    CoreRelayConnection(try await blocking { try RelayConnection.connect(options: options) })
  }
  /// `message` events carry decoded `data: Data`; the stream ends when the connection closes.
  func events() -> AsyncThrowingStream<[String: Any], Error> {
    let inner = self.inner
    return AsyncThrowingStream { continuation in
      let thread = Thread {
        while !Thread.current.isCancelled {
          do {
            guard let text = try inner.nextEvent(timeoutMs: 500) else { continue }
            var event = try RelayCodec.json(text)
            if let data = event["data"] as? String { event["data"] = Data(base64Encoded: data) ?? Data() }
            continuation.yield(event)
          } catch { continuation.finish(throwing: error); return }
        }
      }
      thread.name = "relay-events"
      thread.start()
      // Ending the stream stops reading; the owner closes the connection explicitly.
      continuation.onTermination = { _ in thread.cancel() }
    }
  }
  func message(to: String, data: Data, offline: Bool, id: String?) async throws {
    let inner = self.inner
    _ = try await blocking { try inner.message(to: to, data: data, offline: offline, id: id) }
  }
  func acknowledge(id: String, from: String, offline: Bool) async throws {
    let inner = self.inner
    _ = try await blocking { try inner.acknowledge(from: from, id: id, offline: offline) }
  }
  func peers() async throws -> [RelayPeer] {
    let inner = self.inner
    let reply = try RelayCodec.json(try await blocking { try inner.peers() })
    return (reply["devices"] as? [[String: Any]] ?? []).compactMap {
      guard let app = $0["app"] as? String, let group = $0["group"] as? String, let device = $0["device"] as? String else { return nil }
      return RelayPeer(app: app, group: group, device: device)
    }
  }
  func close() async { inner.disconnect() }
}

/// Encrypted relay files (vault-core `RelayFileClient`; both encryption layers live in the core).
final class CoreRelayFiles: @unchecked Sendable {
  let inner: RelayFileClient
  init(options: String) throws { inner = try RelayFileClient(options: options) }
  func inbox() async throws -> [[String: Any]] {
    let inner = self.inner
    let text = try await blocking { try inner.inbox() }
    return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] ?? []
  }
  func receive(_ descriptor: [String: Any]) async throws -> Data {
    let inner = self.inner, text = try RelayCodec.text(descriptor)
    return try await blocking { try inner.receive(descriptor: text) }
  }
  func acknowledge(id: String) async throws {
    let inner = self.inner
    try await blocking { try inner.acknowledge(id: id) }
  }
  func send(to: String, data: Data) async throws {
    let inner = self.inner
    try await blocking { try inner.send(to: to, data: data) }
  }
  func close() async {}
}

/// The vault-core group state machine for one config. `persist` must durably store each draft;
/// it is awaited from the core's thread before the request that commits the draft.
final class CoreGroups: @unchecked Sendable {
  private(set) var config: [String: Any]
  private let allowLocal: Bool
  private let persist: @Sendable ([String: Any]) async throws -> Void

  init(config: [String: Any], allowLocal: Bool = false, persist: @escaping @Sendable ([String: Any]) async throws -> Void) {
    self.config = config; self.allowLocal = allowLocal; self.persist = persist
  }

  func set(_ key: String, _ value: Any?) { config[key] = value }

  private final class Store: RelayGroupStore, @unchecked Sendable {
    let persist: @Sendable ([String: Any]) async throws -> Void
    weak var owner: CoreGroups?
    init(_ persist: @escaping @Sendable ([String: Any]) async throws -> Void, owner: CoreGroups) { self.persist = persist; self.owner = owner }
    func save(config: String) throws {
      let value = try RelayCodec.json(config)
      // Keep the in-memory config in step so a failing request never re-saves a stale config.
      owner?.config = value
      let done = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var failure: Error?
      Task.detached { do { try await self.persist(value) } catch { failure = error }; done.signal() }
      done.wait()
      if failure != nil { throw RelayError.Failed(code: "Storage") }
    }
  }

  @discardableResult
  private func run(_ op: String, _ extra: [String: Any] = [:]) async throws -> Any? {
    var request = extra
    request["op"] = op; request["config"] = config; request["allowLocal"] = allowLocal
    let text = try RelayCodec.text(request), store = Store(persist, owner: self)
    let reply = try RelayCodec.json(try await blocking { try relayGroups(request: text, store: store) })
    config = reply["config"] as? [String: Any] ?? config
    return reply["result"]
  }

  func create(name: String, deviceName: String) async throws { try await run("create", ["name": name, "deviceName": deviceName]) }
  /// A non-empty `passwordOverride` replaces the link's server password.
  func resolveInvitation(_ link: String, passwordOverride: String?) async throws -> [String: Any] {
    var extra: [String: Any] = ["link": link]
    if let passwordOverride, !passwordOverride.isEmpty { extra["override"] = passwordOverride }
    guard let invitation = try await run("resolve", extra) as? [String: Any] else { throw RelayFault.invalid("invitation") }
    return invitation
  }
  func join(_ invitation: [String: Any], name: String) async throws -> Bool { try await run("join", ["invitation": invitation, "name": name]) as? Bool == true }
  func finishJoin() async throws -> Bool { try await run("finish-join") as? Bool == true }
  /// `{state, online}` after verifying the chain.
  func refresh() async throws -> [String: Any] { try await run("refresh") as? [String: Any] ?? [:] }
  /// Short link for a fresh or still-valid invitation.
  func invite(automatic: Bool) async throws -> String { try await run("invite", ["mode": automatic ? "auto" : "manual"]) as? String ?? "" }
  func pending() async throws { try await run("pending") }
  /// The UI shows the code on both devices; approving confirms they match.
  func approve(manager: Bool) async throws {
    let code = try await run("code") as? String ?? ""
    try await run("approve", ["code": code, "manager": manager])
  }
  func cancel() async throws { try await run("cancel") }
  func rename(device: String, name: String) async throws { try await run("rename", ["device": device, "name": name]) }
  func remove(device: String) async throws { try await run("remove", ["device": device]) }
  func exit(disband: Bool) async throws { try await run("exit", ["disband": disband]) }
  /// Offline check that the signed exit is allowed (e.g. not the last manager leaving others).
  func checkExit(disband: Bool) async throws { try await run("check-exit", ["disband": disband]) }
}

/// Compact `common-relay://` invitation links (sealed/parsed in vault-core).
enum RelayInvitationLinks {
  static func parse(_ link: String, allowLocalTest: Bool = false) throws -> (url: String, id: String, key: Data, password: String?) {
    let p = try RelayCodec.call(CoreRequest.relayProtocolParseLink(link: link, allowLocal: allowLocalTest))
    guard let url = p["url"] as? String, let id = p["id"] as? String, let key = p["key"] as? String else { throw RelayFault.invalid("invitation link") }
    return (url, id, try Data(relayHex: key), p["password"] as? String)
  }
  static func make(_ invitation: [String: Any], key: Data, password: String? = nil) throws -> String {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(try RelayCodec.text(invitation).utf8))
    let local = (invitation["url"] as? String)?.hasPrefix("ws://127.0.0.1:") == true
    guard let link = try RelayCodec.call(CoreRequest.relayProtocolMakeLink(invitation: value, key: key.relayHex, password: password, allowLocal: local))["link"] as? String
    else { throw RelayFault.invalid("invitation link") }
    return link
  }
}
