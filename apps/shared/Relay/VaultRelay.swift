import Foundation
import Combine
import CryptoKit
import Security
import CommonRelay

/// UI and lifecycle owner. Secrets live in Keychain; the core owns business persistence.
@MainActor
final class VaultRelay: ObservableObject {
  struct Config: Codable {
    var endpoint = ""
    var role: String
    var group = ""
    var device = UUID().uuidString.lowercased()
    var hub = ""
    var secret: Data
    var token = ""
    var peers: [String: String] = [:]
    var paused = true
  }
  @Published var config: Config
  @Published var status = "未连接 / Disconnected"
  @Published var summary: [String: JSONValue] = [:]
  @Published var pairingText = ""
  @Published var verificationCode = ""
  @Published var lastSuccess: Date?
  @Published var failure: String?
  private let directory: URL
  private let account: String
  private let call: ([String: JSONValue]) async throws -> JSONValue
  private let refresh: () async -> Void
  private var loop: Task<Void, Never>?
  private var reader: Task<Void, Never>?
  private var client: RelayClient?
  private var journal: RelayJournal?
  private var files: RelayFiles?
  private var active = false
  private var generation = UUID()
  private var invitation: (nonce: String, expires: Date)?
  private var sent: [String: String] = [:]
  private var retryRequested = false

  init(directory: URL, role: String,
       call: @escaping ([String: JSONValue]) async throws -> JSONValue,
       refresh: @escaping () async -> Void) {
    self.directory = directory.appendingPathComponent("relay-private", isDirectory: true)
    account = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    self.call = call; self.refresh = refresh
    config = Config(role: role, secret: RelayIdentity.generateSecretKey())
    do {
      if let data = try Self.load(account) { config = try JSONDecoder().decode(Config.self, from: data) }
      else { if role == "hub" { config.group = UUID().uuidString.lowercased(); config.hub = config.device }; try persist() }
    } catch { failure = "无法读取中继安全配置 / Cannot read secure relay configuration" }
  }
  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.securepass.vault.personal-relay.v1", kSecAttrAccount as String: account]
  }
  private static func load(_ account: String) throws -> Data? {
    var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?; let code = SecItemCopyMatching(q as CFDictionary, &result)
    if code == errSecItemNotFound { return nil }
    guard code == errSecSuccess, let data = result as? Data else { throw RelayError.invalid("Keychain") }; return data
  }
  private func persist() throws {
    let data = try JSONEncoder().encode(config); let q = Self.query(account)
    let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecItemNotFound {
      var entry = q; entry[kSecValueData as String] = data
      entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw RelayError.invalid("Keychain write") }
    } else if update != errSecSuccess { throw RelayError.invalid("Keychain update") }
  }
  private func identity() throws -> RelayIdentity {
    try RelayIdentity(app: "passwordvault", group: config.group, device: config.device, secretKey: config.secret,
                      trustedPeers: config.peers.mapValues { try Data(relayHex: $0) })
  }
  var publicKey: String { (try? identity().publicKey.relayHex) ?? "" }
  func importCredential(_ text: String, endpoint: String) async {
    await action {
      guard let url = URL(string: endpoint), url.scheme == "wss", url.host != nil,
            url.path == "/relay/v1/ws", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let own = value["identity"] as? [String: Any], own["app"] as? String == "passwordvault",
            own["public_key"] as? String == publicKey, let group = own["group"] as? String,
            let device = own["device"] as? String, let token = value["token"] as? String, !token.isEmpty
      else { throw RelayError.invalid("credential identity / WSS endpoint") }
      let current = try await call(["op": .string("relay-status")]).object
      if current["enabled"]?.bool == true {
        guard current["group"]?.string == group, current["device"]?.string == device else { throw RelayError.invalid("already bound") }
      }
      config.endpoint = endpoint; config.group = group; config.device = device; config.token = token
      if config.role == "hub" { config.hub = device }
      try persist()
      if config.role == "hub" { try await initialize() }
      status = "凭据已导入 / Credential imported"
      restart()
    }
  }
  private func initialize() async throws {
    let current = try await call(["op": .string("relay-status")]).object
    if current["enabled"]?.bool == true {
      guard current["group"]?.string == config.group, current["hub"]?.string == config.hub,
            current["device"]?.string == config.device else { throw RelayError.invalid("vault binding") }
      return
    }
    _ = try await call(["op": .string("relay-init"), "role": .string(config.role), "group": .string(config.group),
                       "device": .string(config.device), "hub": .string(config.hub)])
  }
  private func encode(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
  }
  func invite() async {
    await action {
      guard config.role == "hub", !config.token.isEmpty else { throw RelayError.invalid("import credentials first") }
      try await initialize()
      let nonce = UUID().uuidString.lowercased(), expires = Date().addingTimeInterval(300)
      invitation = (nonce, expires)
      pairingText = try encode(["version": 1, "group": config.group, "hub": config.device, "key": publicKey,
                                "endpoint": config.endpoint, "nonce": nonce, "expires": Int(expires.timeIntervalSince1970)])
    }
  }
  private func code(nonce: String, hubKey: String, mobileKey: String) -> String {
    Data(SHA256.hash(data: Data((nonce + "\n" + hubKey + "\n" + mobileKey).utf8))).prefix(4).relayHex.uppercased()
  }
  func pair(_ text: String) async {
    await action {
      guard !config.token.isEmpty, let p = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            p["version"] as? Int == 1, p["group"] as? String == config.group,
            let nonce = p["nonce"] as? String, let key = p["key"] as? String,
            try Data(relayHex: key).count == 32 else { throw RelayError.invalid("pairing identity") }
      let peer: String
      if config.role == "mobile" {
        guard let hub = p["hub"] as? String, p["endpoint"] as? String == config.endpoint,
              let expiry = p["expires"] as? Int, Date().timeIntervalSince1970 < Double(expiry),
              Double(expiry) <= Date().timeIntervalSince1970 + 310 else { throw RelayError.invalid("expired invitation") }
        peer = hub; config.hub = hub
        verificationCode = code(nonce: nonce, hubKey: key, mobileKey: publicKey)
        pairingText = try encode(["version": 1, "group": config.group, "device": config.device, "key": publicKey, "nonce": nonce])
      } else {
        guard let challenge = invitation, challenge.nonce == nonce, challenge.expires > Date(),
              let device = p["device"] as? String else { throw RelayError.invalid("expired or reused invitation") }
        peer = device
        verificationCode = code(nonce: nonce, hubKey: publicKey, mobileKey: key)
        // UI previews the same code before explicit approval invokes this operation.
        invitation = nil
      }
      if let pinned = config.peers[peer], pinned != key { throw RelayError.invalid("public key changed") }
      try await initialize()
      config.peers[peer] = key; try persist()
      _ = try await call(["op": .string("relay-trust"), "peer": .string(peer)])
      config.paused = false; try persist(); restart()
      status = "已配对，等待同步 / Paired; awaiting sync"
    }
  }
  func previewCode(_ text: String) -> String {
    guard config.role == "hub", let invitation,
          let p = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          p["nonce"] as? String == invitation.nonce, let key = p["key"] as? String else { return "" }
    return code(nonce: invitation.nonce, hubKey: publicKey, mobileKey: key)
  }
  func revoke(_ peer: String) async {
    await action {
      _ = try await call(["op": .string("relay-revoke"), "peer": .string(peer)])
      config.peers.removeValue(forKey: peer); try persist(); restart(); try await updateSummary()
    }
  }
  func resolve(_ conflict: String, choice: String) async {
    await action { _ = try await call(["op": .string("relay-resolve"), "conflict": .string(conflict), "choice": .string(choice)]); try await updateSummary(); await refresh(); sent.removeAll() }
  }
  func setPaused(_ paused: Bool) async { await action { config.paused = paused; try persist(); restart() } }
  func setUnlocked(_ unlocked: Bool) {
    guard active != unlocked else { return }; active = unlocked
    if unlocked { restart() } else { stop(); summary = [:]; pairingText = ""; verificationCode = ""; invitation = nil }
  }
  func syncNow() { sent.removeAll(); retryRequested = true; if loop == nil { restart() } }
  private func stop() {
    generation = UUID(); loop?.cancel(); loop = nil; reader?.cancel(); reader = nil
    let old = client; let oldFiles = files; client = nil; files = nil
    Task { await old?.close(); await oldFiles?.close() }
    status = active ? "已暂停 / Paused" : "已锁定 / Locked"
  }
  private func restart() {
    stop(); guard active, !config.paused, !config.token.isEmpty, !config.peers.isEmpty else { return }
    let epoch = generation
    loop = Task { [weak self] in await self?.run(epoch) }
  }
  private func updateSummary() async throws { summary = try await call(["op": .string("relay-status")]).object }
  private func action(_ body: () async throws -> Void) async {
    failure = nil
    do { try await body() } catch { failure = "中继操作失败，请检查配对、凭据或网络 / Relay operation failed; check pairing, credentials or network" }
  }
  private func run(_ epoch: UUID) async {
    var backoff: UInt64 = 1
    while active && generation == epoch && !Task.isCancelled {
      var ownedClient: RelayClient?
      var ownedFiles: RelayFiles?
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if journal == nil { journal = try RelayJournal(directory: directory.appendingPathComponent("journal")) }
        let identity = try identity(), connection = RelayClient(identity: identity, journal: journal)
        client = connection; ownedClient = connection
        guard let ws = URL(string: config.endpoint), var components = URLComponents(url: ws, resolvingAgainstBaseURL: false) else { throw RelayError.invalid("URL") }
        components.scheme = "https"; components.path = "/relay/v1/files"
        let fileClient = try RelayFiles(base: components.url!, token: config.token); files = fileClient; ownedFiles = fileClient
        status = "正在连接 / Connecting"
        let events = try await connection.connect(url: ws, token: config.token)
        guard generation == epoch, active else { await connection.close(); return }
        status = "已连接 / Connected"; failure = nil; backoff = 1; sent.removeAll()
        reader = Task { [weak self] in
          do {
            for try await event in events {
              guard let self, self.active, self.generation == epoch else { return }
              if event["type"] as? String == "message", let data = event["data"] as? Data,
                 let from = event["from"] as? String, let id = event["id"] as? String {
                try await self.receive(data, from: from, epoch: epoch)
                try await connection.acknowledge(id: id, from: from, offline: event["offline"] as? Bool ?? false)
              } else if event["type"] as? String == "peer.up" { self.sent.removeAll() }
            }
            self?.retryRequested = true
          } catch { self?.retryRequested = true }
        }
        retryRequested = false
        while active && generation == epoch && !Task.isCancelled && !retryRequested {
          try await updateSummary()
          for peer in config.peers.keys.sorted() {
            let packet = try await call(["op": .string("relay-export"), "peer": .string(peer)])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(packet)
            let digest = Data(SHA256.hash(data: data)).relayHex
            let period = Int(Date().timeIntervalSince1970 / 3600)
            let signature = digest + ":" + String(period)
            guard sent[peer] != signature else { continue }
            guard generation == epoch, active else { return }
            if data.count <= 128 * 1024 {
              let id = String(Data(SHA256.hash(data: Data((peer + signature).utf8))).relayHex.prefix(32))
              _ = try await connection.message(to: peer, data: data, offline: true, id: id)
            } else { try await sendFile(data, peer: peer, identity: identity, files: fileClient) }
            sent[peer] = signature
          }
          for event in try await fileClient.inbox() {
            guard let id = event["id"] as? String, let from = event["from"] as? String,
                  config.peers[from] != nil, let size = event["size"] as? NSNumber,
                  size.int64Value <= 768 * 1024 * 1024 else { throw RelayError.invalid("file sender or size") }
            let cipher = directory.appendingPathComponent(UUID().uuidString + ".download")
            let inner = directory.appendingPathComponent(UUID().uuidString + ".sealed")
            defer { try? FileManager.default.removeItem(at: cipher); try? FileManager.default.removeItem(at: inner) }
            try await fileClient.download(id: id, ciphertext: cipher)
            let metadata = try RelayFileCrypto.decrypt(identity: identity, from: from, descriptor: event.object, ciphertext: cipher, destination: inner)
            guard let key = metadata["key"] as? String, metadata["format"] as? String == "passwordvault.sync.v1" else { throw RelayError.invalid("file format") }
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: inner)), using: SymmetricKey(data: Data(relayHex: key)))
            try await receive(bytes, from: from, epoch: epoch)
            try await fileClient.acknowledge(id: id)
          }
          try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        reader?.cancel(); await connection.close(); await fileClient.close()
      } catch {
        if generation == epoch && active { status = "等待重连 / Waiting to reconnect"; failure = "同步尚未完成，改动保留在本机 / Sync incomplete; local changes retained" }
        if generation == epoch { reader?.cancel() }
        await ownedClient?.close(); await ownedFiles?.close()
      }
      if Task.isCancelled || generation != epoch { return }
      try? await Task.sleep(nanoseconds: backoff * 1_000_000_000); backoff = min(backoff * 2, 30)
    }
  }
  private func receive(_ data: Data, from: String, epoch: UUID) async throws {
    guard active, generation == epoch, config.peers[from] != nil else { throw RelayError.closed }
    let packet = try JSONDecoder().decode(JSONValue.self, from: data)
    _ = try await call(["op": .string("relay-receive"), "peer": .string(from), "packet": packet])
    guard active, generation == epoch else { throw RelayError.closed }
    lastSuccess = Date(); try await updateSummary(); await refresh()
    // A mobile snapshot receipt must not immediately trigger an identical reply loop.
    if config.role == "hub" { sent.removeAll() }
  }
  private func sendFile(_ data: Data, peer: String, identity: RelayIdentity, files: RelayFiles) async throws {
    // The SDK file API uses paths. Stage an inner AES-GCM ciphertext, never vault plaintext.
    let key = SymmetricKey(size: .bits256)
    let source = directory.appendingPathComponent(UUID().uuidString + ".sealed")
    let destination = directory.appendingPathComponent(UUID().uuidString + ".upload")
    defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
    guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw RelayError.invalid("seal") }
    try sealed.write(to: source, options: .atomic)
    let keyHex = key.withUnsafeBytes { Data($0).relayHex }
    let prepared = try RelayFileCrypto.prepare(identity: identity, to: peer, source: source, ciphertext: destination,
                                               metadata: ["format": "passwordvault.sync.v1", "key": keyHex])
    _ = try await files.upload(prepared)
  }
}
