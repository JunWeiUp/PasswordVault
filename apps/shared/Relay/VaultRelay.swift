import Foundation
import Combine
import CryptoKit
import Security
import LocalAuthentication

/// The unlocked vault core encrypts local credentials; Keychain is a read-only legacy migration source.
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
    var serverPassword: String?
    var peers: [String: String] = [:]
    var paused = true
    var groupState: Data?
  }
  @Published private(set) var credentialsReady = false
  @Published private(set) var credentialAccessBlocked = false
  @Published var groupBusy = false
  @Published var groupFresh = false
  @Published var groupName = ""
  @Published var groupMembers: [GroupMember] = []
  @Published var config: Config
  @Published var status = "未连接 / Disconnected"
  /// True while the relay connection is open. UI state only; never used for sync decisions.
  @Published private(set) var connected = false
  @Published private(set) var connecting = false
  @Published var summary: [String: JSONValue] = [:]
  @Published var pairingText = ""
  @Published var lastSuccess: Date?
  @Published var failure: String?
  private let allowLocalGroupTest: Bool
  private let credentialReader: (String, Bool) throws -> Data?
  private let directory: URL
  private let account: String
  private let call: ([String: JSONValue]) async throws -> JSONValue
  private let refresh: () async -> Void
  /// The open core session for the shared sync session (vault-core `RelayMeshSync`).
  private let session: (() async throws -> VaultSession)?
  private var loop: Task<Void, Never>?
  private var client: CoreMeshSync?
  private var active = false
  private var generation = UUID()
  private var retryRequested = false
  private var transportFailure: String?
  private var credentialLoadTask: Task<Void, Never>?
  private var credentialLoadGeneration = UUID()

  init(directory: URL, role: String, allowLocalGroupTest: Bool = false,
       call: @escaping ([String: JSONValue]) async throws -> JSONValue,
       refresh: @escaping () async -> Void,
       session: (() async throws -> VaultSession)? = nil,
       credentialReader: ((String, Bool) throws -> Data?)? = nil) {
    self.credentialReader = credentialReader ?? Self.load
    self.allowLocalGroupTest = allowLocalGroupTest
    self.directory = directory.appendingPathComponent("relay-private", isDirectory: true)
    account = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    self.call = call; self.refresh = refresh; self.session = session
    config = Config(role: role, secret: RelayIdentity.generateSecretKey())
    // No credential access before the vault is unlocked.
  }
  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.securepass.vault.personal-relay.v1", kSecAttrAccount as String: account]
  }
  private enum CredentialError: Error { case status(OSStatus), unavailable }
  private static func credentialOperation<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
    try operation()
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
    _ = try await call(CoreRequest.relayCredentialsWrite(data: encoded))
  }
  private func loadCredentials(allowLegacyInteraction: Bool) async {
    guard active, !credentialsReady else { return }
    let epoch = credentialLoadGeneration
    groupBusy = true; failure = nil
    defer { if credentialLoadGeneration == epoch { groupBusy = false } }
    do {
      let result = try await call(CoreRequest.relayCredentialsRead())
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
          loaded = Config(role: config.role, secret: RelayIdentity.generateSecretKey())
        }
        let encoded = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
        _ = try await call(CoreRequest.relayCredentialsWrite(data: encoded))
        let verified = try await call(CoreRequest.relayCredentialsRead())
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
      try await updateSummary(); restart()
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
  private var trustedPeers: [String: String] {
    hasManagedGroup ? (groupDictionary["trusted_peers"] as? [String: String] ?? [:]) : config.peers
  }
  /// Connection/file options for the current credentials (vault-core relay transport).
  private func relayOptions(journal: Bool) throws -> String {
    try RelayCodec.options(url: config.endpoint, token: config.token, password: config.serverPassword, group: config.group,
                           device: config.device, secret: config.secret, trusted: trustedPeers,
                           journal: journal ? directory.appendingPathComponent("journal") : nil, allowLocal: allowLocalGroupTest)
  }
  var publicKey: String { (try? RelayCodec.publicKey(secret: config.secret)) ?? "" }
  private func encode(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
  }
  func setUnlocked(_ unlocked: Bool) {
    guard active != unlocked else { return }; active = unlocked
    credentialLoadGeneration = UUID(); credentialLoadTask?.cancel(); credentialLoadTask = nil
    if unlocked {
      credentialLoadTask = Task { [weak self] in await self?.loadCredentials(allowLegacyInteraction: false) }
    } else {
      groupFresh = false; groupMembers = []; stop(); summary = [:]; pairingText = ""
      credentialsReady = false; credentialAccessBlocked = false; groupBusy = false
      config = Config(role: config.role, secret: Data(repeating: 0, count: 32))
    }
  }
  func syncNow() { forceSend = true; retryRequested = true; if loop == nil { restart() } }
  private var forceSend = false
  private func stop() {
    generation = UUID(); loop?.cancel(); loop = nil
    let old = client; client = nil
    old?.close()
    setGroupOnline([]); connected = false; connecting = false
    status = active ? "未连接 / Disconnected" : "已锁定 / Locked"
  }
  private func restart() {
    // Only members of a personal device group sync (symmetric mesh).
    stop(); guard active, credentialsReady, !credentialAccessBlocked, !groupInvalid, !config.token.isEmpty,
      hasManagedGroup else { return }
    let epoch = generation
    loop = Task { [weak self] in await self?.run(epoch) }
  }
  private func updateSummary() async throws {
    summary = try await call(CoreRequest.relayStatus()).object
  }

  private func action(_ body: () async throws -> Void) async {
    guard active, credentialsReady, !credentialAccessBlocked else { return }
    failure = nil
    do { try await body() } catch { failure = "中继操作失败，请检查配对、凭据或网络 / Relay operation failed; check pairing, credentials or network" }
  }
  private func run(_ epoch: UUID) async {
    // Delays follow the shared owner policy in vault-core (relay_protocol::policy).
    var backoff: UInt64 = 0
    while active && generation == epoch && !Task.isCancelled {
      var owned: CoreMeshSync?
      var connectedAt: Date?
      var failedError: String?
      do {
        try await refreshGroupForConnection(epoch)
        guard active, generation == epoch, !Task.isCancelled else { return }
        guard let session else { throw RelayFault.invalid("no vault session") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        status = "正在连接 / Connecting"; connecting = true
        // The shared sync session in vault-core owns the sync rules (roster, delivery, dedup,
        // undecryptable and group-change handling); this loop only drives it.
        let sync = try await CoreMeshSync.connect(vault: try await session(), options: try relayOptions(journal: true))
        client = sync; owned = sync
        guard generation == epoch, active else { sync.close(); return }
        status = connectedStatus; connected = true; connecting = false
        if failure == transportFailure { failure = nil }; transportFailure = nil
        connectedAt = Date()
        let groups = try RelayCodec.text(groupDictionary)
        retryRequested = false
        while active && generation == epoch && !Task.isCancelled {
          let force = forceSend; forceSend = false
          let round = try await sync.cycle(groups: groups, force: force)
          guard active, generation == epoch, !Task.isCancelled else { return }
          setGroupOnline(Set(round["online"] as? [String] ?? []).union([config.device]))
          if round["changed"] as? Bool == true { await refresh() }
          lastSuccess = Date()
          // Handle relay events for ~5 s; a manual sync request ends the wait early.
          for _ in 0..<5 where !retryRequested {
            let pumped = try await sync.pump(timeoutMs: 1000)
            guard active, generation == epoch else { return }
            if pumped["changed"] as? Bool == true { await refresh() }
            if let reason = pumped["reconnect"] as? String { throw RelayFault.invalid("reconnect: " + reason) }
          }
          retryRequested = false
        }
        if generation == epoch { setGroupOnline([]); connected = false }
        sync.close()
      } catch {
        failedError = RelayCodec.code(error)
        if generation == epoch && active {
          setGroupOnline([]); connected = false; connecting = false; status = "等待重连 / Waiting to reconnect"
          transportFailure = "同步尚未完成，改动保留在本机 / Sync incomplete; local changes retained"
          if failure == nil { failure = transportFailure }
        }
        owned?.close()
      }
      if Task.isCancelled || generation != epoch { return }
      let connectedSeconds = connectedAt.map { UInt64(max(0, Date().timeIntervalSince($0))) } ?? 0
      guard let delay = Self.retryDelay(failedError ?? "closed", previous: backoff, connected: connectedSeconds) else {
        status = "同步服务拒绝凭据，已停止重连 / Sync access rejected; reconnecting stopped"
        failure = "服务器密码错误或接入令牌被拒绝，请修改服务器密码后重试；组身份已保留。 / Server access denied; update the server password and retry."
        return
      }
      backoff = delay
      try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
    }
  }

}

extension VaultRelay {
  private var connectedStatus: String {
    (meshPeers ?? []).isEmpty ? "中继已连接，等待组内其他设备 / Relay connected; waiting for other devices"
      : "已连接 · 自动双向同步 / Connected · syncing both ways"
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
  /// A personal device group is set up on this device but the relay is not reachable right
  /// now, so changes stay encrypted on this device until it reconnects.
  var offline: Bool { credentialsReady && hasManagedGroup && !connected && !connecting }
  /// Signed-roster members with pinned keys, excluding this device. Joining the group is
  /// the only admission step for symmetric sync; nil outside a personal group.
  var meshPeers: [String]? {
    guard let entry = groupDictionary["group_entry"] as? [String: Any],
          groupDictionary["access_invalid"] as? Bool != true,
          let state = try? RelayCodec.unpack(entry), state["closed"] as? Bool != true,
          let members = state["members"] as? [[String: Any]] else { return nil }
    let trusted = groupDictionary["trusted_peers"] as? [String: String] ?? [:]
    return members.compactMap { $0["device"] as? String }
      .filter { $0 != config.device && !(trusted[$0] ?? "").isEmpty }.sorted()
  }
  var isLegacyGroup: Bool { !config.token.isEmpty && config.groupState == nil }
  var joiningGroup: Bool { groupDictionary["pending_join"] != nil }
  var creatingGroup: Bool { groupDictionary["pending_create"] != nil }
  var pendingCreationNames: (group: String, device: String)? {
    guard let entry = groupDictionary["pending_create"] as? [String: Any],
          let payload = try? RelayCodec.unpack(entry), let name = payload["name"] as? String,
          let members = payload["members"] as? [[String: Any]],
          let own = members.first(where: { $0["device"] as? String == config.device }),
          let deviceName = own["name"] as? String else { return nil }
    return (name, deviceName)
  }
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
    guard let request, let raw = try? RelayCodec.payload(request) else { return "" }
    let code = Array(RelayCodec.digest(raw).prefix(12).uppercased())
    return stride(from: 0, to: 12, by: 4).map { String(code[$0..<$0+4]) }.joined(separator: "-")
  }
  var applicantName: String {
    guard groupFresh, let entry = groupDictionary["join_request"] as? [String: Any],
          let body = try? RelayCodec.unpack(entry), let member = body["member"] as? [String: Any] else { return "" }
    return member["name"] as? String ?? ""
  }
  private var groupDictionary: [String: Any] {
    guard let bytes = config.groupState else { return [:] }
    return (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
  }
  private func groups() throws -> CoreGroups {
    guard !isLegacyGroup else { throw RelayFault.invalid("legacy access requires explicit reset") }
    var value = groupDictionary
    if value.isEmpty {
      value = ["app": "passwordvault", "device": config.device, "secret_key": config.secret.relayHex]
    }
    if let password = config.serverPassword { value["password"] = password }
    // vault-core persists each signed draft through this callback before sending it.
    return CoreGroups(config: value, allowLocal: allowLocalGroupTest) { [weak self] draft in try await self?.storeGroup(draft) }
  }
  private func storeGroup(_ value: [String: Any]) async throws {
    guard active, credentialsReady else { throw CredentialError.unavailable }
    config.endpoint = value["url"] as? String ?? config.endpoint
    config.serverPassword = value["password"] as? String ?? config.serverPassword
    config.groupState = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try await persist()
  }
  private func saveGroup(_ groups: CoreGroups) async throws { try await storeGroup(groups.config) }
  private func applyGroup(_ groups: CoreGroups, online: [String] = []) async throws {
    try await saveGroup(groups)
    guard active else { throw CancellationError() }
    guard let entry = groups.config["group_entry"] as? [String: Any] else { return }
    let state = try RelayCodec.unpack(entry), members = state["members"] as? [[String: Any]] ?? []
    guard state["closed"] as? Bool != true, members.contains(where: { $0["device"] as? String == config.device }) else {
      try await invalidateGroup(); throw RelayFault.invalid("group access revoked")
    }
    config.endpoint = groups.config["url"] as? String ?? ""
    config.group = groups.config["group"] as? String ?? ""
    config.token = groups.config["token"] as? String ?? ""
    let trusted = groups.config["trusted_peers"] as? [String: String] ?? [:]
    // Symmetric sync reads the signed roster each cycle; legacy pinned keys are pruned.
    for (id, key) in config.peers where trusted[id] != key {
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
    let g = try groups(); g.set("access_invalid", true); try await saveGroup(g)
  }
  var groupInvalid: Bool { groupDictionary["access_invalid"] as? Bool == true }
  private func groupAction(_ body: (CoreGroups) async throws -> Void) async {
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

      failure = groupInvalid ? "设备组接入已失效。确认清除本机接入后，可重新创建或加入。 / Group access expired. Clear local access to rejoin."
        : message.contains("401") ? "服务器密码错误或接入令牌被拒绝，请修改服务器密码后重试；组身份已保留。 / Server access denied; update the server password and retry." : (message.contains("404") || message.contains("410") || message.contains("expired") || message.contains("invitation scope"))
          ? "邀请无效或已过期，请向邀请人获取新邀请；当前输入已保留。 / Invitation invalid or expired; request a new invitation. Your input is retained."
        : error is URLError
          ? "无法连接服务器，请检查网络后重试；当前输入已保留。 / Cannot reach the server. Check your connection and retry; input is retained."
        : "设备组操作未完成，草稿已保留。请检查输入、权限或服务端是否为 passwordvault 开启自助创建。 / Group operation incomplete; retry draft retained."
    }
  }
  static func validateServerPassword(_ value: String) throws {
    guard (8...128).contains(value.utf8.count), value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
      throw RelayFault.invalid("server password required (printable ASCII, no spaces)")
    }
  }
  static func validateEndpoint(_ value: String, allowLocalTest: Bool = false) throws -> String {
    guard let u = URLComponents(string: value), let host = u.host, !host.isEmpty,
          u.scheme == "wss" || (allowLocalTest && u.scheme == "ws" && host == "127.0.0.1"),
          (u.path == "/relay/v1/ws" || u.path == "/v2/ws"), u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else {
      throw RelayFault.invalid("WSS endpoint required: wss://host/v2/ws or wss://host/relay/v1/ws")
    }
    return value
  }
  /// Read locally only. Reading a QR never sends an enrollment request.
  static func inspectInvitation(_ text: String) throws -> (endpoint: String, password: String?) {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.hasPrefix("common-relay:") {
      let p = try RelayInvitationLinks.parse(input)
      return (p.url, p.password)
    }
    guard input.utf8.count <= 16384,
          let v = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
          v["app"] as? String == "passwordvault", let url = v["url"] as? String else { throw RelayFault.invalid("invitation") }
    return (try validateEndpoint(url), v["password"] as? String)
  }
  func updateServerPassword(_ password: String) async {
    guard credentialsReady, !credentialAccessBlocked, !groupBusy, active else { return }
    groupBusy = true; stop(); defer { groupBusy = false; restart() }
    await action {
      try Self.validateServerPassword(password)
      let previous = config
      config.serverPassword = password
      var value = groupDictionary
      if !value.isEmpty {
        value["password"] = password
        // Earlier clients mistook a server-password 401 for membership revocation.
        value.removeValue(forKey: "access_invalid")
        if var pending = value["pending_join"] as? [String: Any], var inv = pending["invitation"] as? [String: Any] {
          inv["password"] = password; pending["invitation"] = inv; value["pending_join"] = pending
        }
        config.groupState = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      }
      do { try await persist() } catch { config = previous; throw error }
      status = "服务器密码已保存，请重试 / Server password saved; retry"
    }
  }
  func createGroup(endpoint: String, name: String, deviceName: String, password: String? = nil) async {
    await groupAction { g in
      guard !hasManagedGroup, !joiningGroup, config.token.isEmpty else { throw RelayFault.invalid("already configured") }
      if creatingGroup { guard endpoint == g.config["url"] as? String else { throw RelayFault.invalid("creation endpoint is fixed") } }
      if let password { try Self.validateServerPassword(password); g.set("password", password) }
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RelayFault.invalid("group name required") }
      _ = try Self.validateEndpoint(endpoint, allowLocalTest: allowLocalGroupTest)
      g.set("url", endpoint)
      try await g.create(name: name, deviceName: deviceName); try await applyGroup(g)
      status = "设备组已创建，可邀请设备加入 / Group created; invite your devices"
    }
  }
  func joinGroup(_ text: String, deviceName: String, password: String? = nil) async {
    await groupAction { g in
      guard !hasManagedGroup, !creatingGroup, config.token.isEmpty, text.utf8.count <= 16384 else { throw RelayFault.invalid("invitation scope") }
      let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if let password { try Self.validateServerPassword(password) }
      var inv: [String: Any]
      if input.hasPrefix("common-relay:") { inv = try await g.resolveInvitation(input, passwordOverride: password) }
      else {
        guard let value = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { throw RelayFault.invalid("invitation") }
        inv = value
      }
      if let password { inv["password"] = password }
      guard inv["app"] as? String == "passwordvault" else { throw RelayFault.invalid("invitation scope") }
      if let old = (g.config["pending_join"] as? [String: Any])?["invitation"] as? [String: Any] {
        guard NSDictionary(dictionary: old).isEqual(to: inv) else { throw RelayFault.invalid("another join pending") }
      }
      let joined = try await g.join(inv, name: deviceName); try await saveGroup(g)
      if inv["mode"] as? String == "auto" {
        guard try await (joined ? true : g.finishJoin()) else { throw RelayFault.invalid("automatic join incomplete") }
        try await applyGroup(g)
        status = "已加入设备组，开始自动双向同步 / Joined; syncing both ways"
      } else { status = "请核对双方配对码，再由邀请方批准 / Compare codes before approval" }
    }
  }
  func retryGroupJoin() async {
    await groupAction { g in
      guard let pending = g.config["pending_join"] as? [String: Any], let inv = pending["invitation"] as? [String: Any],
            let request = pending["request"] as? [String: Any], let member = try RelayCodec.unpack(request)["member"] as? [String: Any],
            let name = member["name"] as? String else { throw RelayFault.invalid("join request") }
      let joined = try await g.join(inv, name: name); try await saveGroup(g)
      if inv["mode"] as? String == "auto", try await (joined ? true : g.finishJoin()) { try await applyGroup(g) }
    }
  }
  func finishGroupJoin() async {
    await groupAction { g in
      guard try await g.finishJoin() else { status = "等待邀请方批准 / Waiting for approval"; return }
      try await applyGroup(g)
      status = "已加入设备组，开始自动双向同步 / Joined; syncing both ways"
    }
  }
  func refreshGroup() async {
    await groupAction { g in
      let result = try await g.refresh(); try await applyGroup(g, online: result["online"] as? [String] ?? [])
    }
  }
  func inviteToGroup(automatic: Bool = true) async {
    await groupAction { g in
      // Reuses a still-valid invitation and its short link; publishing is retried idempotently.
      _ = try await g.invite(automatic: automatic)
      try await applyGroup(g)
    }
  }
  func checkGroupRequest() async {
    await groupAction { g in
      guard let inv = g.config["issued_invitation"] as? [String: Any] else { throw RelayFault.invalid("invitation") }
      guard inv["mode"] as? String != "auto" else { throw RelayFault.invalid("automatic invitation") }
      try await g.pending()
      let result = try await g.refresh(); try await applyGroup(g, online: result["online"] as? [String] ?? [])
      if g.config["join_request"] == nil { status = "尚无加入申请 / No join request yet" }
    }
  }
  func approveGroupRequest(manager: Bool) async {
    await groupAction { g in
      guard g.config["issued_invitation"] != nil, g.config["join_request"] != nil else { throw RelayFault.invalid("request") }
      try await g.approve(manager: manager)
      try await applyGroup(g)
    }
  }
  func cancelGroupInvitation() async {
    await groupAction { g in
      guard g.config["issued_invitation"] != nil else { return }
      try await g.cancel()
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
      try await g.checkExit(disband: disband) // Never orphan a group: validate before clearing.
      let snapshot = g.config
      // Owner policy: clear local state first; the relay notice is best-effort and uses a
      // detached snapshot that can never restore membership.
      try await clearGroupAccess()
      guard snapshot["group_entry"] != nil, snapshot["exit_completed"] as? Bool != true else { return }
      let remote = CoreGroups(config: snapshot, allowLocal: allowLocalGroupTest) { _ in }
      let confirmed = (try? await remote.exit(disband: disband)) != nil
      status = confirmed ? "本机已退出，服务器已确认 / Left locally; server confirmed"
        : "本机已退出，服务器确认未完成 / Left locally; server not confirmed"
    }
  }
  // Also used for explicit legacy reset or invalid local access. Never claims a
  // server-side revocation when only local configuration is cleared.
  func clearLocalGroup() async {
    guard credentialsReady, !credentialAccessBlocked, !groupBusy, active else { return }; groupBusy = true; stop()
    defer { groupBusy = false }
    await action { try await clearGroupAccess() }
  }
  /// Shared retry policy from vault-core: nil means stop (401/403); otherwise 1 s doubling to
  /// 30 s, reset only after a 120 s connection.
  nonisolated static func retryDelay(_ error: String, previous: UInt64, connected: UInt64) -> UInt64? {
    let request = CoreRequest.relayProtocolRetry(error: error, previousDelay: Double(previous), connectedSeconds: Double(connected))
    guard let data = try? JSONEncoder().encode(request), let reply = try? relayProtocol(request: String(decoding: data, as: UTF8.self)),
          let value = try? JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8)) else { return 30 }
    if value.object["stop"]?.bool == true { return nil }
    return UInt64(value.object["delay"]?.number ?? 30)
  }
  private func clearGroupAccess() async throws {
    let state = try await call(CoreRequest.relayStatus()).object
    if state["enabled"]?.bool == true {
      _ = try await call(["op": .string("relay-detach"), "group": state["group"] ?? .null, "device": state["device"] ?? .null])
    }
    let old = config
    config.groupState = nil; config.group = ""; config.token = ""; config.hub = ""
    // Owner policy (vault-core relay_protocol::policy): clear the server password, keep the
    // endpoint, rotate the device ID and (unless a peer library pins it) the X25519 transport key.
    let fresh = try await call(CoreRequest.relayProtocolExitIdentity()).object
    guard let device = fresh["device"]?.string, let secret = try? Data(relayHex: fresh["secret"]?.string ?? ""), secret.count == 32
    else { throw RelayFault.invalid("identity") }
    config.peers = [:]; config.paused = true; config.device = device
    config.serverPassword = nil
    config.secret = secret
    do { try await persist() } catch { config = old; throw error }
    groupMembers = []; groupFresh = false; groupName = ""; pairingText = ""
    try await updateSummary(); status = "本机接入已清除，本地资料保留 / Local access cleared; vault retained"
  }
  private func refreshGroupForConnection(_ epoch: UUID) async throws {
    guard hasManagedGroup else { return }
    guard !groupBusy, !groupInvalid else { throw RelayFault.invalid("group unavailable") }
    groupBusy = true; defer { groupBusy = false }
    let g = try groups()
    do {
      let result = try await g.refresh()
      guard active, generation == epoch, !Task.isCancelled else { throw CancellationError() }
      try await applyGroup(g, online: result["online"] as? [String] ?? [])
    } catch {
      groupFresh = false; groupMembers = []

      throw error
    }
  }
}
