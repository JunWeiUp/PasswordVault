import Foundation
import Combine
import CryptoKit
import Security
import LocalAuthentication
import CommonRelay

/// The unlocked vault core encrypts local credentials; Keychain is a read-only legacy migration source.
@MainActor
final class VaultRelay: ObservableObject {
  struct VaultGrant: Codable {
    var revision: Int
    var enabled: Bool
    var acknowledged = false
    var key: String?
  }
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
    var groupState: Data?
    var vaultGrants: [String: VaultGrant]?
    var accessRevision: Int?
    var accessEnabled: Bool?
  }
  @Published private(set) var credentialsReady = false
  @Published private(set) var credentialAccessBlocked = false
  @Published var groupBusy = false
  @Published var groupFresh = false
  @Published var groupName = ""
  @Published var groupMembers: [GroupMember] = []
  @Published var config: Config
  @Published var status = "未连接 / Disconnected"
  @Published var summary: [String: JSONValue] = [:]
  @Published var pairingText = ""
  @Published var verificationCode = ""
  @Published var lastSuccess: Date?
  @Published var failure: String?
  private let allowLocalGroupTest: Bool
  private let credentialReader: (String, Bool) throws -> Data?
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
  private var transportFailure: String?
  private var credentialLoadTask: Task<Void, Never>?
  private var credentialLoadGeneration = UUID()

  init(directory: URL, role: String, allowLocalGroupTest: Bool = false,
       call: @escaping ([String: JSONValue]) async throws -> JSONValue,
       refresh: @escaping () async -> Void,
       credentialReader: ((String, Bool) throws -> Data?)? = nil) {
    self.credentialReader = credentialReader ?? Self.load
    self.allowLocalGroupTest = allowLocalGroupTest
    self.directory = directory.appendingPathComponent("relay-private", isDirectory: true)
    account = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    self.call = call; self.refresh = refresh
    config = Config(role: role, secret: RelayIdentity.generateSecretKey())
    // No credential access before the vault is unlocked.
  }
  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.securepass.vault.personal-relay.v1", kSecAttrAccount as String: account]
  }
  private enum CredentialError: Error { case status(OSStatus), unavailable }
  // Legacy macOS login-Keychain ACL prompts do not reliably honor LAContext.
  // Scope the legacy switch to a synchronous MainActor operation and restore it
  // immediately; never disable interaction for unrelated biometric operations.
  private static func credentialOperation<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
    #if os(macOS)
    var previous = DarwinBoolean(true)
    let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
    guard readStatus == errSecSuccess else { throw CredentialError.status(readStatus) }
    let setStatus = SecKeychainSetUserInteractionAllowed(allowInteraction)
    guard setStatus == errSecSuccess else { throw CredentialError.status(setStatus) }
    defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
    #endif
    return try operation()
  }
  private static func load(_ account: String, _ allowInteraction: Bool) throws -> Data? {
    try credentialOperation(allowInteraction: allowInteraction) {
      var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
      let context = LAContext(); context.interactionNotAllowed = !allowInteraction
      q[kSecUseAuthenticationContext as String] = context
      var result: CFTypeRef?; let code = SecItemCopyMatching(q as CFDictionary, &result)
      if code == errSecItemNotFound { return nil }
      guard code == errSecSuccess, let data = result as? Data else { throw CredentialError.status(code) }
      return data
    }
  }
  private func persist() async throws {
    guard active, credentialsReady, !credentialAccessBlocked else { throw CredentialError.unavailable }
    let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    _ = try await call(["op": .string("relay-credentials-write"), "data": .string(encoded)])
  }
  private func loadCredentials(allowLegacyInteraction: Bool) async {
    guard active, !credentialsReady else { return }
    let epoch = credentialLoadGeneration
    groupBusy = true; failure = nil
    defer { if credentialLoadGeneration == epoch { groupBusy = false } }
    do {
      let result = try await call(["op": .string("relay-credentials-read")])
      guard active, credentialLoadGeneration == epoch, !Task.isCancelled else { return }
      let loaded: Config
      var migratedLegacy = false
      switch result.object["data"] {
      case .some(.string(let text)):
        loaded = try JSONDecoder().decode(Config.self, from: Data(text.utf8))
      case .some(.null):
        if let legacy = try credentialReader(account, allowLegacyInteraction) {
          loaded = try JSONDecoder().decode(Config.self, from: legacy)
          migratedLegacy = true
        } else {
          var fresh = Config(role: config.role, secret: RelayIdentity.generateSecretKey())
          if fresh.role == "hub" { fresh.group = UUID().uuidString.lowercased(); fresh.hub = fresh.device }
          loaded = fresh
        }
        let encoded = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
        _ = try await call(["op": .string("relay-credentials-write"), "data": .string(encoded)])
        let verified = try await call(["op": .string("relay-credentials-read")])
        guard verified.object["data"]?.string == encoded else { throw CredentialError.unavailable }
      default: throw CredentialError.unavailable
      }
      guard active, credentialLoadGeneration == epoch, !Task.isCancelled else { return }
      config = loaded; credentialsReady = true; credentialAccessBlocked = false
      if migratedLegacy {
        // Verified local ciphertext is authoritative. Best-effort legacy cleanup
        // must never open a system dialog or invalidate a successful migration.
        try? Self.credentialOperation(allowInteraction: false) {
          let result = SecItemDelete(Self.query(account) as CFDictionary)
          guard result == errSecSuccess || result == errSecItemNotFound else { throw CredentialError.status(result) }
        }
      }
      restart()
    } catch {
      guard active, credentialLoadGeneration == epoch, !Task.isCancelled else { return }
      credentialAccessBlocked = true
      failure = "中继凭据无法读取。旧版钥匙串如需授权，请主动迁移；原接入和加密文件均保留。 / Relay credentials unavailable. Explicitly migrate legacy access if needed; existing credentials and encrypted files are preserved."
    }
  }
  func restoreCredentialAccess() async {
    guard credentialAccessBlocked, !groupBusy else { return }
    await loadCredentials(allowLegacyInteraction: true)
  }
  private func identity() throws -> RelayIdentity {
    try RelayIdentity(app: "passwordvault", group: config.group, device: config.device, secretKey: config.secret,
                      trustedPeers: (hasManagedGroup ? (groupDictionary["trusted_peers"] as? [String: String] ?? [:]) : config.peers).mapValues { try Data(relayHex: $0) })
  }
  var publicKey: String { (try? identity().publicKey.relayHex) ?? "" }
  func importCredential(_ text: String, endpoint: String) async {
    await action {
      guard config.groupState == nil else { throw RelayError.invalid("managed group") }
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
      try await persist()
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
      if hasManagedGroup {
        let g = try groups(); _ = try await g.refresh(); try await applyGroup(g)
        guard (g.config["trusted_peers"] as? [String: String])?[peer] == key else { throw RelayError.invalid("peer is not a group member") }
      }
      if let pinned = config.peers[peer], pinned != key { throw RelayError.invalid("public key changed") }
      try await initialize()
      config.peers[peer] = key; try await persist()
      _ = try await call(["op": .string("relay-trust"), "peer": .string(peer)])
      config.paused = false; try await persist(); restart()
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
    if hasManagedGroup && config.role == "hub" { await setVaultAccess(peer, enabled: false); return }
    await action {
      config.accessEnabled = false
      _ = try await call(["op": .string("relay-revoke"), "peer": .string(peer)])
      config.peers.removeValue(forKey: peer); try await persist(); restart(); try await updateSummary()
    }
  }
  func resolve(_ conflict: String, choice: String) async {
    await action { _ = try await call(["op": .string("relay-resolve"), "conflict": .string(conflict), "choice": .string(choice)]); try await updateSummary(); await refresh(); sent.removeAll() }
  }
  func setPaused(_ paused: Bool) async { await action { config.paused = paused; try await persist(); restart() } }
  func setUnlocked(_ unlocked: Bool) {
    guard active != unlocked else { return }; active = unlocked
    credentialLoadGeneration = UUID(); credentialLoadTask?.cancel(); credentialLoadTask = nil
    if unlocked {
      credentialLoadTask = Task { [weak self] in await self?.loadCredentials(allowLegacyInteraction: false) }
    } else {
      groupFresh = false; groupMembers = []; stop(); summary = [:]; pairingText = ""; verificationCode = ""; invitation = nil
      credentialsReady = false; credentialAccessBlocked = false; groupBusy = false
      config = Config(role: config.role, secret: Data(repeating: 0, count: 32))
    }
  }
  func syncNow() { sent.removeAll(); retryRequested = true; if loop == nil { restart() } }
  private func stop() {
    generation = UUID(); loop?.cancel(); loop = nil; reader?.cancel(); reader = nil
    let old = client; let oldFiles = files; client = nil; files = nil
    Task { await old?.close(); await oldFiles?.close() }
    setGroupOnline([])
    status = active ? "未连接 / Disconnected" : "已锁定 / Locked"
  }
  private func restart() {
    stop(); guard active, credentialsReady, !credentialAccessBlocked, !groupInvalid, !config.token.isEmpty,
      hasManagedGroup || (!config.paused && !config.peers.isEmpty) else { return }
    let epoch = generation
    loop = Task { [weak self] in await self?.run(epoch) }
  }
  private func updateSummary() async throws { summary = try await call(["op": .string("relay-status")]).object }
  private func action(_ body: () async throws -> Void) async {
    guard active, credentialsReady, !credentialAccessBlocked else { return }
    failure = nil
    do { try await body() } catch { failure = "中继操作失败，请检查配对、凭据或网络 / Relay operation failed; check pairing, credentials or network" }
  }
  private func run(_ epoch: UUID) async {
    var backoff: UInt64 = 1
    while active && generation == epoch && !Task.isCancelled {
      var ownedClient: RelayClient?
      var ownedFiles: RelayFiles?
      do {
        try await refreshGroupForConnection(epoch)
        guard active, generation == epoch, !Task.isCancelled else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if journal == nil { journal = try RelayJournal(directory: directory.appendingPathComponent("journal")) }
        let identity = try identity(), connection = RelayClient(identity: identity, journal: journal)
        client = connection; ownedClient = connection
        guard let ws = URL(string: config.endpoint), var components = URLComponents(url: ws, resolvingAgainstBaseURL: false) else { throw RelayError.invalid("URL") }
        components.scheme = allowLocalGroupTest && ws.scheme == "ws" ? "http" : "https"; components.path = "/relay/v1/files"
        let fileClient = try RelayFiles(base: components.url!, token: config.token, allowLocalTest: allowLocalGroupTest); files = fileClient; ownedFiles = fileClient
        status = "正在连接 / Connecting"
        let events = try await connection.connect(url: ws, token: config.token, allowLocalTest: allowLocalGroupTest)
        guard generation == epoch, active else { await connection.close(); return }
        status = connectedStatus
        if failure == transportFailure { failure = nil }; transportFailure = nil
        backoff = 1; sent.removeAll()
        reader = Task { [weak self] in
          do {
            for try await event in events {
              guard let self, self.active, self.generation == epoch else { return }
              if event["type"] as? String == "message", let data = event["data"] as? Data,
                 let from = event["from"] as? String, let id = event["id"] as? String {
                if try await self.receiveAuthorization(data, from: from, connection: connection) == false {
                  guard !self.config.paused, self.config.peers[from] != nil else { continue }
                  try await self.receive(data, from: from, epoch: epoch)
                }
                try await connection.acknowledge(id: id, from: from, offline: event["offline"] as? Bool ?? false)
              } else if event["type"] as? String == "group.changed",
                        (event["revision"] as? Int ?? 0) > self.groupRevision {
                self.retryRequested = true
                await connection.close(); return
              } else if event["type"] as? String == "peer.up" { self.sent.removeAll() }
            }
            self?.retryRequested = true
          } catch { self?.retryRequested = true }
        }
        retryRequested = false
        while active && generation == epoch && !Task.isCancelled && !retryRequested {
          if hasManagedGroup {
            let devices = try await connection.peers()
            guard active, generation == epoch, !Task.isCancelled else { return }
            setGroupOnline(Set(devices.filter { $0.app == "passwordvault" && $0.group == config.group }.map(\.device)).union([config.device]))
          }
          try await sendAuthorizations(connection)
          if !config.paused && !config.peers.isEmpty {
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
          }
          try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if generation == epoch { setGroupOnline([]) }
        reader?.cancel(); await connection.close(); await fileClient.close()
      } catch {
        if generation == epoch && active {
          setGroupOnline([]); status = "等待重连 / Waiting to reconnect"
          transportFailure = "同步尚未完成，改动保留在本机 / Sync incomplete; local changes retained"
          if failure == nil { failure = transportFailure }
        }
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

// Device-group access never grants vault read/write authority. Vault pairing below
// remains a separate, explicit confirmation between the Mac and a replica.
extension VaultRelay {
  private var connectedStatus: String {
    if config.peers.isEmpty { return "中继已连接，密码库尚未授权 / Relay connected; vault not authorized" }
    if config.paused { return "中继已连接，密码库同步已暂停 / Relay connected; vault sync paused" }
    return "已连接 / Connected"
  }
  private func setGroupOnline(_ ids: Set<String>) {
    groupMembers = groupMembers.map { GroupMember(id: $0.id, name: $0.name, manager: $0.manager, online: ids.contains($0.id)) }
  }
  struct GroupMember: Identifiable {
    let id: String
    let name: String
    let manager: Bool
    let online: Bool
  }
  var hasManagedGroup: Bool { groupDictionary["group_entry"] != nil }
  var isLegacyGroup: Bool { !config.token.isEmpty && config.groupState == nil }
  var joiningGroup: Bool { groupDictionary["pending_join"] != nil }
  var creatingGroup: Bool { groupDictionary["pending_create"] != nil }
  var groupManager: Bool { groupFresh && groupMembers.contains { $0.id == config.device && $0.manager } }
  var groupInvite: String {
    guard groupFresh, let inv = groupDictionary["issued_invitation"] as? [String: Any],
          (inv["expires"] as? Double ?? 0) > Date().timeIntervalSince1970 else { return "" }
    return inv["short_link"] as? String ?? (try? encode(inv)) ?? ""
  }
  var automaticGroupJoin: Bool {
    let inv = (groupDictionary["pending_join"] as? [String: Any])?["invitation"] as? [String: Any]
      ?? groupDictionary["issued_invitation"] as? [String: Any]
    return inv?["mode"] as? String == "auto"
  }
  var groupCode: String {
    let d = groupDictionary
    let request = (d["pending_join"] as? [String: Any])?["request"] as? [String: Any] ?? d["join_request"] as? [String: Any]
    guard let request, let raw = try? RelayGroups.payload(request) else { return "" }
    let code = Array(RelayGroups.digest(raw).prefix(12).uppercased())
    return stride(from: 0, to: 12, by: 4).map { String(code[$0..<$0+4]) }.joined(separator: "-")
  }
  var applicantName: String {
    guard groupFresh, let entry = groupDictionary["join_request"] as? [String: Any],
          let body = try? RelayGroups.unpack(entry), let member = body["member"] as? [String: Any] else { return "" }
    return member["name"] as? String ?? ""
  }
  private var groupDictionary: [String: Any] {
    guard let bytes = config.groupState else { return [:] }
    return (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
  }
  private func groups() throws -> RelayGroups {
    guard !isLegacyGroup else { throw RelayError.invalid("legacy access requires explicit reset") }
    var value = groupDictionary
    if value.isEmpty {
      value = ["app": "passwordvault", "device": config.device, "secret_key": config.secret.relayHex]
    }
    pinVaultAuthority(&value)
    return RelayGroups(config: value, allowLocalTest: allowLocalGroupTest)
  }
  private func saveGroup(_ groups: RelayGroups) async throws {
    guard active, credentialsReady else { throw CredentialError.unavailable }
    pinVaultAuthority(&groups.config)
    config.groupState = try JSONSerialization.data(withJSONObject: groups.config, options: [.sortedKeys])
    try await persist()
  }
  private func applyGroup(_ groups: RelayGroups, online: [String] = []) async throws {
    try await saveGroup(groups)
    guard active else { throw CancellationError() }
    guard let entry = groups.config["group_entry"] as? [String: Any] else { return }
    let state = try RelayGroups.unpack(entry), members = state["members"] as? [[String: Any]] ?? []
    guard state["closed"] as? Bool != true, members.contains(where: { $0["device"] as? String == config.device }) else {
      try await invalidateGroup(); throw RelayError.invalid("group access revoked")
    }
    config.endpoint = groups.config["url"] as? String ?? ""
    config.group = groups.config["group"] as? String ?? ""
    config.token = groups.config["token"] as? String ?? ""
    if config.role == "hub" { config.hub = config.device }
    let trusted = groups.config["trusted_peers"] as? [String: String] ?? [:]
    for (id, var grant) in config.vaultGrants ?? [:] where trusted[id] != grant.key {
      grant.enabled = false; grant.acknowledged = true; config.vaultGrants?[id] = grant
    }
    // Revoked or changed identities lose business authorization before reconnect.
    for (id, key) in config.peers where trusted[id] != key {
      _ = try await call(["op": .string("relay-revoke"), "peer": .string(id)])
      config.peers.removeValue(forKey: id)
    }
    try await persist()
    groupName = state["name"] as? String ?? config.group
    groupMembers = members.compactMap { m in
      guard let id = m["device"] as? String else { return nil }
      return GroupMember(id: id, name: m["name"] as? String ?? id, manager: m["manager"] as? Bool ?? false, online: online.contains(id))
    }
    groupFresh = true
  }
  private func invalidateGroup() async throws {
    config.paused = true; groupFresh = false; groupMembers = []
    let g = try groups(); g.config["access_invalid"] = true; try await saveGroup(g)
  }
  var groupRevision: Int {
    guard let entry = groupDictionary["group_entry"] as? [String: Any] else { return 0 }
    return (try? RelayGroups.unpack(entry)["revision"] as? Int) ?? 0
  }
  var groupInvalid: Bool { groupDictionary["access_invalid"] as? Bool == true }
  private func groupAction(_ body: (RelayGroups) async throws -> Void) async {
    guard credentialsReady, !credentialAccessBlocked, !groupBusy, active else { return }
    groupBusy = true; failure = nil; stop()
    defer { groupBusy = false; restart() }
    do {
      let g = try groups()
      do { try await body(g) }
      catch {
        // Keep signed retry drafts, including conflict-cleared exit state.
        try await saveGroup(g)
        throw error
      }
    } catch {
      groupFresh = false; groupMembers = []
      let message = String(describing: error)
      if hasManagedGroup && message.contains("401") { try? await invalidateGroup() }
      failure = groupInvalid ? "设备组接入已失效。确认清除本机接入后，可重新创建或加入。 / Group access expired. Clear local access to rejoin."
        : "设备组操作未完成，草稿已保留。请检查网络、权限或服务端是否为 passwordvault 开启自助创建。 / Group operation incomplete; retry draft retained."
    }
  }
  func createGroup(endpoint: String, name: String, deviceName: String) async {
    await groupAction { g in
      guard !hasManagedGroup, !joiningGroup, config.token.isEmpty else { throw RelayError.invalid("already configured") }
      if !creatingGroup { g.config["url"] = endpoint }
      try g.prepareCreate(groupName: name, deviceName: deviceName); try await saveGroup(g)
      try await g.create(); try await applyGroup(g)
      status = "设备组已创建，请授权密码库同步 / Group created; authorize vault sync next"
    }
  }
  func joinGroup(_ text: String, deviceName: String) async {
    await groupAction { g in
      guard !hasManagedGroup, !creatingGroup, config.token.isEmpty, text.utf8.count <= 16384 else { throw RelayError.invalid("invitation scope") }
      let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let inv: [String: Any]
      if input.hasPrefix("common-relay:") { inv = try await g.resolveInvitation(input) }
      else {
        guard let value = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { throw RelayError.invalid("invitation") }
        inv = value
      }
      guard inv["app"] as? String == "passwordvault" else { throw RelayError.invalid("invitation scope") }
      if let old = (g.config["pending_join"] as? [String: Any])?["invitation"] as? [String: Any] {
        guard NSDictionary(dictionary: old).isEqual(to: inv) else { throw RelayError.invalid("another join pending") }
      }
      g.config["url"] = inv["url"]; g.config["group"] = inv["group"]
      try g.prepareJoin(inv, name: deviceName); try await saveGroup(g)
      try await g.join(inv, name: deviceName); try await saveGroup(g)
      if inv["mode"] as? String == "auto" {
        guard try await g.finishJoin() else { throw RelayError.invalid("automatic join incomplete") }
        try await applyGroup(g)
        status = "已加入设备组，密码库同步尚未授权 / Joined; vault sync needs separate authorization"
      } else { status = "请核对双方配对码，再由邀请方批准 / Compare codes before approval" }
    }
  }
  func retryGroupJoin() async {
    await groupAction { g in
      guard let pending = g.config["pending_join"] as? [String: Any], let inv = pending["invitation"] as? [String: Any],
            let request = pending["request"] as? [String: Any], let member = try RelayGroups.unpack(request)["member"] as? [String: Any],
            let name = member["name"] as? String else { throw RelayError.invalid("join request") }
      try await g.join(inv, name: name); try await saveGroup(g)
      if inv["mode"] as? String == "auto", try await g.finishJoin() { try await applyGroup(g) }
    }
  }
  func finishGroupJoin() async {
    await groupAction { g in
      guard try await g.finishJoin() else { status = "等待邀请方批准 / Waiting for approval"; return }
      try await applyGroup(g)
      status = "已加入设备组，密码库同步尚未授权 / Joined; vault sync needs separate authorization"
    }
  }
  func refreshGroup() async {
    await groupAction { g in
      let result = try await g.refresh(); try await applyGroup(g, online: result["online"] as? [String] ?? [])
    }
  }
  func inviteToGroup(automatic: Bool = true) async {
    await groupAction { g in
      if var old = g.config["issued_invitation"] as? [String: Any], (old["expires"] as? Double ?? 0) > Date().timeIntervalSince1970 {
        if old["short_link"] == nil {
          _ = try await g.publishInvitation(&old); g.config["issued_invitation"] = old
        }
        try await applyGroup(g); return
      }
      var inv = try await g.invite(mode: automatic ? "auto" : "manual")
      g.config["issued_invitation"] = inv; try await saveGroup(g)
      _ = try await g.publishInvitation(&inv)
      g.config["issued_invitation"] = inv; g.config.removeValue(forKey: "join_request")
      try await applyGroup(g)
    }
  }
  func checkGroupRequest() async {
    await groupAction { g in
      guard let inv = g.config["issued_invitation"] as? [String: Any] else { throw RelayError.invalid("invitation") }
      guard inv["mode"] as? String != "auto" else { throw RelayError.invalid("automatic invitation") }
      g.config["join_request"] = try await g.pending(inv)
      let result = try await g.refresh(); try await applyGroup(g, online: result["online"] as? [String] ?? [])
      if g.config["join_request"] == nil { status = "尚无加入申请 / No join request yet" }
    }
  }
  func approveGroupRequest(manager: Bool) async {
    await groupAction { g in
      guard let inv = g.config["issued_invitation"] as? [String: Any], let req = g.config["join_request"] as? [String: Any] else { throw RelayError.invalid("request") }
      try await g.approve(inv, request: req, manager: manager)
      g.config.removeValue(forKey: "issued_invitation"); g.config.removeValue(forKey: "join_request")
      try await applyGroup(g)
    }
  }
  func cancelGroupInvitation() async {
    await groupAction { g in
      guard let inv = g.config["issued_invitation"] as? [String: Any] else { return }
      try await g.cancel(inv); g.config.removeValue(forKey: "issued_invitation"); g.config.removeValue(forKey: "join_request")
      try await applyGroup(g)
    }
  }
  func renameGroupMember(_ device: String, name: String) async {
    await groupAction { g in try await g.rename(device: device, name: name); try await applyGroup(g) }
  }
  func removeGroupMember(_ device: String) async {
    await groupAction { g in try await g.remove(device: device); try await applyGroup(g) }
  }
  func leaveGroup(disband: Bool) async {
    await groupAction { g in
      if (g.config["pending_exit"] != nil || g.config["exit_completed"] as? Bool == true), let intent = g.config["exit_disband"] as? Bool { guard intent == disband else { throw RelayError.invalid("exit pending") } }
      g.config["exit_disband"] = disband
      if g.config["exit_completed"] as? Bool != true {
        try await g.prepareExit(disband: disband); try await saveGroup(g)
        try await g.exit(); g.config["exit_completed"] = true; try await saveGroup(g)
      }
      try await clearGroupAccess()
    }
  }
  // Also used for explicit legacy reset or invalid local access. Never claims a
  // server-side revocation when only local configuration is cleared.
  func clearLocalGroup() async {
    guard credentialsReady, !credentialAccessBlocked, !groupBusy, active else { return }; groupBusy = true; stop()
    defer { groupBusy = false }
    await action { try await clearGroupAccess() }
  }
  private func clearGroupAccess() async throws {
    let state = try await call(["op": .string("relay-status")]).object
    if state["enabled"]?.bool == true {
      _ = try await call(["op": .string("relay-detach"), "group": state["group"] ?? .null, "device": state["device"] ?? .null])
    }
    let old = config
    config.groupState = nil; config.group = ""; config.token = ""; config.hub = ""
    config.vaultGrants = nil; config.accessRevision = nil; config.accessEnabled = nil
    config.peers = [:]; config.paused = true; config.device = UUID().uuidString.lowercased()
    do { try await persist() } catch { config = old; throw error }
    groupMembers = []; groupFresh = false; groupName = ""; pairingText = ""; verificationCode = ""; invitation = nil
    try await updateSummary(); status = "本机接入已清除，本地资料保留 / Local access cleared; vault retained"
  }
  private func refreshGroupForConnection(_ epoch: UUID) async throws {
    guard hasManagedGroup else { return }
    guard !groupBusy, !groupInvalid else { throw RelayError.invalid("group unavailable") }
    groupBusy = true; defer { groupBusy = false }
    let g = try groups()
    do {
      let result = try await g.refresh()
      guard active, generation == epoch, !Task.isCancelled else { throw CancellationError() }
      try await applyGroup(g, online: result["online"] as? [String] ?? [])
    } catch {
      groupFresh = false; groupMembers = []
      if String(describing: error).contains("401") { try await invalidateGroup() }
      throw error
    }
  }
}

// Encrypted control messages use verified group identities, while vault packets
// remain gated by the separate explicit grant. No credentials or vault data are
// carried in this handshake.
extension VaultRelay {
  private static let accessFormat = "passwordvault.access.v1"
  private func pinVaultAuthority(_ value: inout [String: Any]) {
    guard config.role == "mobile", value["vault_authority"] == nil,
          let entry = value["group_entry"] as? [String: Any],
          let state = try? RelayGroups.unpack(entry), let members = state["members"] as? [[String: Any]] else { return }
    let managers = members.filter { $0["manager"] as? Bool == true }
    // Migration pins the sole already-verified manager. Ambiguous groups retain
    // explicit pairing; never select a new authority from an incoming message.
    if managers.count == 1, managers[0]["device"] as? String != config.device {
      value["vault_authority"] = managers[0]
    }
  }
  func vaultAccessEnabled(_ peer: String) -> Bool {
    config.vaultGrants?[peer]?.enabled ?? (config.peers[peer] != nil)
  }
  func vaultAccessPending(_ peer: String) -> Bool {
    config.vaultGrants?[peer]?.acknowledged == false
  }
  func setVaultAccess(_ peer: String, enabled: Bool) async {
    guard config.role == "hub", hasManagedGroup, peer != config.device else { return }
    if !enabled {
      guard !groupBusy else { return }
      await action {
        stop()
        defer { restart() }
        let previous = config
        var grants = config.vaultGrants ?? [:]
        grants[peer] = VaultGrant(revision: (grants[peer]?.revision ?? 0) + 1, enabled: false,
                                  key: grants[peer]?.key ?? config.peers[peer] ?? (groupDictionary["trusted_peers"] as? [String: String])?[peer])
        config.vaultGrants = grants; config.peers.removeValue(forKey: peer)
        do { try await persist() } catch { config = previous; throw error }
        if try await call(["op": .string("relay-status")]).object["enabled"]?.bool == true {
          _ = try await call(["op": .string("relay-revoke"), "peer": .string(peer)])
        }
      }
      return
    }
    guard groupManager else { return }
    await groupAction { g in
      _ = try await g.refresh(); try await applyGroup(g)
      guard (g.config["trusted_peers"] as? [String: String])?[peer] != nil else { throw RelayError.invalid("member missing") }
      try await initialize()
      let old = config
      var grants = config.vaultGrants ?? [:]
      grants[peer] = VaultGrant(revision: (grants[peer]?.revision ?? 0) + 1, enabled: enabled, key: (g.config["trusted_peers"] as? [String: String])?[peer])
      config.vaultGrants = grants
      // Deny transport immediately, including while a revoke awaits delivery.
      config.peers.removeValue(forKey: peer)
      do { try await persist() } catch { config = old; throw error }
      _ = try await call(["op": .string("relay-revoke"), "peer": .string(peer)])
    }
  }
  private func accessMessage(_ peer: String, grant: VaultGrant, kind: String) throws -> Data {
    Data(try encode(["format": Self.accessFormat, "kind": kind, "group": config.group,
                     "to": peer, "revision": grant.revision, "enabled": grant.enabled,
                     "permission": "read-write"]).utf8)
  }
  private func sendAuthorizations(_ connection: RelayClient) async throws {
    guard config.role == "hub", groupManager else { return }
    for (peer, grant) in config.vaultGrants ?? [:] where !grant.acknowledged {
      guard groupMembers.contains(where: { $0.id == peer && $0.online }) else { continue }
      guard grant.key == (groupDictionary["trusted_peers"] as? [String: String])?[peer] else { continue }
      _ = try await connection.message(to: peer, data: accessMessage(peer, grant: grant, kind: "set"), offline: false)
    }
  }
  // Internal for failure-path tests; callers pass only SDK-authenticated senders.
  func receiveAuthorization(_ data: Data, from: String, connection: RelayClient) async throws -> Bool {
    guard let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          p["format"] as? String == Self.accessFormat else { return false }
    guard active, credentialsReady, hasManagedGroup, groupFresh, !groupInvalid,
          p["group"] as? String == config.group, p["to"] as? String == config.device,
          p["permission"] as? String == "read-write", let revision = p["revision"] as? Int, revision > 0,
          let enabled = p["enabled"] as? Bool,
          let key = (groupDictionary["trusted_peers"] as? [String: String])?[from] else { return true }
    if config.role == "hub" {
      guard p["kind"] as? String == "ack", var grant = config.vaultGrants?[from],
            grant.revision == revision, grant.enabled == enabled, grant.key == key else { return true }
      if grant.acknowledged { return true }
      let previous = config
      if enabled {
        try await initialize()
        _ = try await call(["op": .string("relay-trust"), "peer": .string(from)])
        config.peers[from] = key; config.paused = false
      }
      grant.acknowledged = true; config.vaultGrants?[from] = grant
      do { try await persist() } catch { if active { config = previous }; throw error }
      sent.removeAll(); status = connectedStatus
    } else {
      guard p["kind"] as? String == "set",
            let authority = groupDictionary["vault_authority"] as? [String: Any],
            authority["device"] as? String == from, authority["public_key"] as? String == key,
            config.hub.isEmpty || config.hub == from,
            revision >= (config.accessRevision ?? 0) else { return true }
      if revision == config.accessRevision {
        guard enabled == config.accessEnabled else { return true }
      } else {
        let previous = config
        config.hub = from; try await initialize()
        if enabled {
          _ = try await call(["op": .string("relay-trust"), "peer": .string(from)])
          config.peers[from] = key; config.paused = false
        } else {
          config.peers.removeValue(forKey: from)
          _ = try await call(["op": .string("relay-revoke"), "peer": .string(from)])
        }
        config.accessRevision = revision; config.accessEnabled = enabled
        do { try await persist() } catch { if active { config = previous }; throw error }
        status = connectedStatus
      }
      _ = try await connection.message(to: from, data: accessMessage(from, grant: VaultGrant(revision: revision, enabled: enabled), kind: "ack"), offline: false)
    }
    return true
  }
}
