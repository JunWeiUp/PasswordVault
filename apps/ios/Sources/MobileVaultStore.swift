import AuthenticationServices
import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class MobileVaultStore: ObservableObject {
  @Published var recoveredDraft: VaultItem?
  private var volatileRecovery: JSONValue?
  var captureRichDraft: (() -> Task<VaultItem?, Never>)?
  var pendingDraft: VaultItem?
  var systemFileFlow = false
  @Published var unlocked = false { didSet { relay.setUnlocked(unlocked) } }
  @Published var exists = false
  @Published var legacyAvailable = false
  private var legacySource: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("db.sqlite")
  }
  @Published var ready = false
  @Published var busy = false
  @Published var items: [VaultItem] = []
  private var lastPasskeyIndex: [JSONValue] = []
  private var credentialSync: Task<Void, Never>?
  @Published var sharedMembers: [JSONValue] = []
  @Published var settings: [String: JSONValue] = [:]
  @Published var error: String?
  @Published var notice: String?
  /// Entry just moved to Trash; the app shows an undo banner for it until it times out.
  @Published var undoTrashID: String?
  @Published var language = UserDefaults.standard.string(forKey: "language") ?? "zh"
  lazy var relay = VaultRelay(directory: directory, role: "mobile", call: { [weak self] request in
    guard let self else { throw VaultError.Locked }
    return try await self.perform(request)
  }, refresh: { [weak self] in try? await self?.refresh() })
  let directory: URL
  private(set) var core: MobileCore?
  private var epoch = 0
  private var closing: Task<Void, Never>?
  private var lastActivity: Date
  private let now: () -> Date
  private var clipboardChange: Int?
  private var idle: AnyCancellable?

  init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
    self.now = now
    lastActivity = now()
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      let testIndex = arguments.firstIndex(of: "--ui-test-vault")
      let testDirectory = testIndex.flatMap { index -> URL? in
        guard arguments.indices.contains(index + 1), UUID(uuidString: arguments[index + 1]) != nil
        else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
          "UI-Test-" + arguments[index + 1])
      }
    #else
      let testDirectory: URL? = nil
    #endif
    self.directory = directory ?? testDirectory ?? VaultLocation.directory
    idle = Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { [weak self] _ in
      self?.checkIdle()
    }
  }
  var chinese: Bool { language == "zh" }
  func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
  func activity() { lastActivity = now() }
  func checkIdle() {
    guard unlocked else { return }
    let minutes = max(1, settings["autoLockMinutes"]?.number ?? 60)
    if now().timeIntervalSince(lastActivity) >= minutes * 60 { lock() }
  }
  func close() async {
    lock()
    await closing?.value
  }
  var canWriteLibrary: Bool {
    if settings["_peerLibraryReadOnly"]?.bool == true { return false }
    if !(settings["activePeerLibrary"]?.string ?? "").isEmpty { return ["admin", "editor"].contains(settings["_peerLibraryRole"]?.string ?? "") }
    return true
  }
  func canEdit(_ item: VaultItem) -> Bool {
    guard canWriteLibrary else { return false }
    let shared = item.string("sharedVaultId")
    if shared.isEmpty { return true }
    let own = settings["sharingIdentity"]?.object["publicKey"]?.string ?? ""
    return sharedMembers.contains {
      $0.object["vaultId"]?.string == shared && $0.object["userPublicKey"]?.string == own
        && ["owner", "editor"].contains($0.object["role"]?.string ?? "")
    }
  }
  var categories: [String] {
    Array(
      Set(
        (settings["noteCategories"]?.array.map(\.string) ?? [])
          + items.filter { $0.type == "secureNote" }.map(\.category))
    ).filter { !$0.isEmpty }.sorted()
  }
  private func connection() throws -> MobileCore {
    if let core { return core }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete])
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
    let value = try MobileCore(directory: directory)
    core = value
    return value
  }
  func start() async {
    do {
      exists =
        try await connection().call(["op": .string("status")]).object["exists"]?.bool ?? false
    } catch { report(error) }
    legacyAvailable = !exists && FileManager.default.fileExists(atPath: legacySource.path)
    ready = true
  }
  func authenticate(_ password: String, create: Bool, legacyPassword: String = "") async {
    guard !busy else { return }
    guard !create || !password.isEmpty else {
      error = t("请填写主密码。", "Enter a master password.")
      return
    }
    busy = true
    error = nil
    let generation = epoch
    defer { busy = false }
    do {
      await closing?.value
      let core = try connection()
      if create && legacyAvailable {
        guard let salt = UserDefaults.standard.string(forKey: "flutter.master_key_salt"),
          !salt.isEmpty
        else { throw VaultError.Unsupported }
        _ = try await core.call([
          "op": .string("create-migrated"), "source": .string(legacySource.path),
          "salt": .string(salt), "legacyPassword": .string(legacyPassword),
          "password": .string(password),
        ])
      } else {
        _ = try await core.call([
          "op": .string(create ? "create" : "unlock"), "password": .string(password),
        ])
      }
      guard generation == epoch else {
        await core.close()
        return
      }
      let document = try await core.document()
      guard generation == epoch else {
        await core.close()
        return
      }
      items = document.items
      settings = document.settings
      sharedMembers = document.sharedMembers
      exists = true
      legacyAvailable = false
      unlocked = true
      activity()
      await recoverDraft(core)
      #if DEBUG
        if create { await installUITestDeviceFixture(password: password) }
      #endif
    } catch {
      if create && legacyAvailable {
        self.error = t(
          "旧库未完成迁移。请检查旧密码；若缺少迁移密钥或包含旧版共享资料，请从旧版导出加密备份再导入。原文件保留。",
          "Legacy migration did not complete. Check the old password; if keys are missing or legacy sharing is present, export an encrypted backup from the old app and import it. Source files are retained."
        )
      } else {
        report(error)
      }
    }
  }
  func createFromBackup(_ content: String, filePassword: String, password: String, kind: String)
    async
  {
    guard !busy, !exists else { return }
    busy = true
    let generation = epoch
    defer { busy = false }
    do {
      await closing?.value
      let core = try connection()
      _ = try await core.call([
        "op": .string("create-from-backup"), "content": .string(content),
        "backupPassword": .string(filePassword), "password": .string(password),
        "kind": .string(kind),
      ])
      guard generation == epoch else {
        await core.close()
        return
      }
      let document = try await core.document()
      guard generation == epoch else {
        await core.close()
        return
      }
      items = document.items
      settings = document.settings
      sharedMembers = document.sharedMembers
      exists = true
      legacyAvailable = false
      unlocked = true
      activity()
    } catch { report(error) }
  }
  func recover(key: String, newPassword: String, archive: String? = nil) async {
    guard !busy, !unlocked, !newPassword.isEmpty else { return }
    busy = true
    error = nil
    let generation = epoch
    defer { busy = false }
    do {
      await closing?.value
      let core = try connection()
      var request: [String: JSONValue] = [
        "op": .string(archive == nil ? "recovery-reset-password" : "recovery-restore-backup"),
        "key": .string(key), "newPassword": .string(newPassword),
      ]
      if let archive { request["content"] = .string(archive) }
      _ = try await core.call(request)
      guard generation == epoch else { await core.close(); return }
      let document = try await core.document()
      guard generation == epoch else { await core.close(); return }
      items = document.items; settings = document.settings; sharedMembers = document.sharedMembers
      exists = true; legacyAvailable = false; unlocked = true
      MobileBiometrics.remove()
      UserDefaults.standard.set(false, forKey: "biometricEnabled")
      activity()
      if archive == nil { await recoverDraft(core) }
    } catch {
      if generation == epoch {
        await core?.close(); core = nil
        exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("vault").path)
        report(error)
      }
    }
  }

  #if DEBUG
    /// UI tests only: upgrades a fresh synthetic UI-test vault to the device format and adds one
    /// fictional device, so the read-only device pages can be exercised. Never touches other vaults.
    private func installUITestDeviceFixture(password: String) async {
      guard ProcessInfo.processInfo.arguments.contains("--ui-test-device-fixture"),
        directory.lastPathComponent.hasPrefix("UI-Test-")
      else { return }
      do {
        _ = try await perform([
          "op": .string("devices-enable"), "confirm": .bool(true), "currentPassword": .string(password),
        ])
        var item = VaultItem.blank(type: "device", title: "Fixture server")
        item.fields["device"] = .object([
          "version": .number(1), "host": .string("server.example.test"), "port": .number(2222),
          "username": .string("deploy"), "authMethod": .string("password"),
          "password": .string("SYNTHETIC-PASSWORD-CANARY"), "privateKey": .string(""),
          "aliases": .array([]), "notes": .string("Rack 2"), "files": .array([]),
          "services": .array([.object([
            "id": .string("web"), "name": .string("Web console"), "kind": .string("browser"),
            "remotePort": .number(443), "localPort": .number(8443), "path": .string("/admin"),
          ])]),
          "commands": .array([.object([
            "id": .string("restart"), "title": .string("Restart service"),
            "text": .string("systemctl restart web"), "secret": .bool(false),
          ])]),
        ])
        item.set("updatedAt", ISO8601DateFormatter().string(from: Date()))
        _ = try await perform(["op": .string("save"), "item": try .from(item)])
        try await refresh()
      } catch { report(error) }
    }
  #endif
  func lock() {
    let capturedRichDraft = captureRichDraft?()
    captureRichDraft = nil
    sharedMembers = []
    epoch += 1
    unlocked = false
    items = []
    settings = [:]
    notice = nil
    undoTrashID = nil
    error = nil
    if clipboardChange == UIPasteboard.general.changeCount { UIPasteboard.general.items = [] }
    clipboardChange = nil
    let previous = core
    core = nil
    let pending = pendingDraft
    pendingDraft = nil
    recoveredDraft = nil
    let background = UIApplication.shared.beginBackgroundTask(withName: "Seal draft")
    closing = Task {
      let pending = await capturedRichDraft?.value ?? pending
      if let previous, let pending {
        do {
          let sealed = try await previous.call([
            "op": .string("seal-drafts"), "items": try .from([pending]),
          ])
          volatileRecovery = sealed
          try JSONEncoder().encode(sealed).write(
            to: directory.appendingPathComponent("mobile-draft.sealed"),
            options: [.atomic, .completeFileProtection])
          volatileRecovery = nil
        } catch {
          self.error = t(
            "草稿暂时加密保留在内存中，请勿退出应用。解锁后重试保存并检查可用空间。",
            "The encrypted draft remains in memory. Do not quit; unlock and retry saving after checking storage."
          )
        }
      }
      await previous?.close()
      if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
    }
  }
  func enrollBiometrics() async {
    guard let core, unlocked else { return }
    do {
      try MobileBiometrics.enroll(await core.biometricKey())
      UserDefaults.standard.set(true, forKey: "biometricEnabled")
      notice = t("生物识别已启用", "Biometric unlock enabled")
    } catch { report(error) }
  }
  func authenticateBiometric() async {
    guard !busy else { return }
    busy = true
    let generation = epoch
    defer { busy = false }
    do {
      let key = try await MobileBiometrics.load(
        reason: t("解锁 PasswordVault", "Unlock PasswordVault"))
      guard generation == epoch else { return }
      await closing?.value
      let core = try connection()
      try await core.unlockBiometric(key)
      let document = try await core.document()
      guard generation == epoch else {
        await core.close()
        return
      }
      items = document.items
      settings = document.settings
      sharedMembers = document.sharedMembers
      unlocked = true
      activity()
      await recoverDraft(core)
    } catch {
      self.error = t(
        "生物识别未完成，请重试或使用主密码。",
        "Biometric unlock did not complete. Retry or use your master password.")
    }
  }
  func discardDraft() {
    pendingDraft = nil
    recoveredDraft = nil
    volatileRecovery = nil
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("mobile-draft.sealed"))
  }
  private func recoverDraft(_ core: MobileCore) async {
    let url = directory.appendingPathComponent("mobile-draft.sealed")
    guard volatileRecovery != nil || FileManager.default.fileExists(atPath: url.path) else {
      return
    }
    do {
      let sealed =
        try volatileRecovery ?? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
      let result = try await core.call([
        "op": .string("open-drafts"), "payload": sealed.object["payload"] ?? .null,
      ])
      guard unlocked else { return }
      if let value = result.object["items"]?.array.first {
        recoveredDraft = try JSONDecoder().decode(VaultItem.self, from: JSONEncoder().encode(value))
        pendingDraft = recoveredDraft
      }
    } catch {
      self.error = t(
        "正式资料库已解锁，但恢复草稿无法读取。草稿文件已保留。",
        "The vault is unlocked, but the recovery draft could not be read. The draft file was retained."
      )
    }
  }
  func perform(_ request: [String: JSONValue]) async throws -> JSONValue {
    guard unlocked, let core else { throw VaultError.Locked }
    if pendingDraft != nil, ["relay-peer-switch", "relay-peer-create", "relay-peer-rekey", "relay-init", "relay-receive", "recovery-export", "history-enable", "history-restore", "history-prune", "share-seal"].contains(request["op"]?.string ?? "") { throw VaultError.InUse }
    let generation = epoch
    let value = try await core.call(request)
    guard generation == epoch, unlocked else { throw VaultError.Locked }
    return value
  }
  func refresh() async throws {
    guard unlocked, let core else { throw VaultError.Locked }
    let generation = epoch
    let document = try await core.document()
    guard generation == epoch, unlocked else { throw VaultError.Locked }
    items = document.items
    settings = document.settings
    sharedMembers = document.sharedMembers
    var passkeys: [JSONValue] = []
    if #available(iOS 17.0, *) {
      let index = try await core.call(["op": .string("passkey-index")])
      guard generation == epoch, unlocked else { throw VaultError.Locked }
      passkeys = index.object["passkeys"]?.array ?? []
    }
    lastPasskeyIndex = passkeys
    syncCredentialIndex()
  }
  /// Re-syncs the system identity store after the QuickType setting changes.
  func refreshCredentialSuggestions() async {
    syncCredentialIndex()
  }
  /// Syncs the system identity store in the background so refresh, unlock and save never wait
  /// on it; syncs run one after another so the latest state wins.
  private func syncCredentialIndex() {
    let previous = credentialSync
    let passkeys = lastPasskeyIndex
    credentialSync = Task { [weak self] in
      await previous?.value
      await self?.refreshCredentialIndex(passkeys: passkeys)
    }
  }
  /// Replaces the system identity store with the current passkeys and, unless turned off,
  /// account suggestions (site, username, entry ID; never passwords). Replacing removes
  /// identities of deleted entries. The system may never call back, so waits are bounded;
  /// a failed sync is retried on the next refresh.
  private func refreshCredentialIndex(passkeys values: [JSONValue]) async {
    let passwords = CredentialSuggestions.enabled ? CredentialSuggestions.identities(items) : []
    if #available(iOS 17.0, *) {
      func decoded(_ value: String) -> Data? {
        var raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        return Data(base64Encoded: raw)
      }
      func identity(_ value: JSONValue) -> ASPasskeyCredentialIdentity? {
        let fields = value.object
        guard let rp = fields["rpId"]?.string, let user = fields["userName"]?.string,
          let id = decoded(fields["id"]?.string ?? ""), !id.isEmpty,
          let handle = decoded(fields["userHandle"]?.string ?? ""), !handle.isEmpty else { return nil }
        return ASPasskeyCredentialIdentity(relyingPartyIdentifier: rp, userName: user, credentialID: id, userHandle: handle, recordIdentifier: fields["id"]?.string)
      }
      let identities: [any ASCredentialIdentity] = values.compactMap(identity) + passwords
      _ = await boundedCompletion(timeout: 5, fallback: false) { done in
        ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities) { success, _ in done(success) }
      }
    } else {
      _ = await boundedCompletion(timeout: 5, fallback: false) { done in
        ASCredentialIdentityStore.shared.replaceCredentialIdentities(with: passwords) { success, _ in done(success) }
      }
    }
  }
  @discardableResult
  func save(_ item: VaultItem) async -> Bool {
    guard !busy else { return false }
    busy = true
    defer { busy = false }
    do {
      var item = item
      let time = ISO8601DateFormatter().string(from: Date())
      item.set("updatedAt", time)
      // New entries record when they were created (used by the notes sort); existing ones keep theirs.
      if item.string("createdAt").isEmpty && !items.contains(where: { $0.id == item.id }) {
        item.set("createdAt", time)
      }
      _ = try await perform(["op": .string("save"), "item": try .from(item)])
      try await refresh()
      activity()
      return true
    } catch {
      report(error)
      return false
    }
  }
  func toggle(_ id: String, field: String) async {
    guard var item = items.first(where: { $0.id == id }) else { return }
    item.fields[field] = .bool(!item.bool(field))
    _ = await save(item)
  }
  @discardableResult
  func trash(_ item: VaultItem) async -> Bool {
    guard var latest = items.first(where: { $0.id == item.id }) else { return false }
    latest.isDeleted = !item.isDeleted
    latest.set("deletedAt", latest.isDeleted ? ISO8601DateFormatter().string(from: Date()) : "")
    if await save(latest) {
      if latest.isDeleted {
        notice = nil
        undoTrashID = latest.id
      } else {
        if undoTrashID == latest.id { undoTrashID = nil }
        notice = t("已恢复", "Restored")
      }
      return true
    }
    return false
  }
  /// Applies one change to several selected entries and saves them, skipping entries this
  /// device may not edit and entries already in Trash. Returns how many were saved; a failure
  /// stops the batch and keeps what was saved before it.
  @discardableResult
  func update(_ ids: Set<String>, where include: (VaultItem) -> Bool = { _ in true }, _ change: (inout VaultItem) -> Void) async -> Int {
    guard !busy, unlocked else { return 0 }
    busy = true
    defer { busy = false }
    let time = ISO8601DateFormatter().string(from: Date())
    var saved = 0
    do {
      for var item in items where ids.contains(item.id) && !item.isDeleted && canEdit(item) && include(item) {
        change(&item)
        item.set("updatedAt", time)
        _ = try await perform(["op": .string("save"), "item": try .from(item)])
        saved += 1
      }
    } catch { report(error) }
    try? await refresh()
    activity()
    return saved
  }
  @discardableResult
  func favorite(_ ids: Set<String>) async -> Int {
    let count = await update(ids) { $0.isFavorite = true }
    if count > 0 { notice = t("已收藏 \(count) 项", "Added \(count) to Favorites") }
    return count
  }
  /// Moves notes to a category ("" clears it). Other entry types are left unchanged.
  @discardableResult
  func move(_ ids: Set<String>, to category: String) async -> Int {
    let name = category.trimmingCharacters(in: .whitespacesAndNewlines)
    let count = await update(ids, where: { $0.type == "secureNote" }) { $0.category = name }
    if count > 0 {
      notice = name.isEmpty ? t("已移出分类 \(count) 项", "Removed \(count) from category")
        : t("已移动 \(count) 项到「\(name)」", "Moved \(count) to “\(name)”")
    }
    return count
  }
  @discardableResult
  func trash(_ ids: Set<String>) async -> Int {
    let time = ISO8601DateFormatter().string(from: Date())
    let count = await update(ids) {
      $0.isDeleted = true
      $0.set("deletedAt", time)
    }
    if count > 0 { undoTrashID = nil; notice = t("已移到回收站 \(count) 项", "Moved \(count) to Trash") }
    return count
  }
  /// Restores the entry from the undo banner, using the latest stored copy.
  func undoTrash() async {
    guard let id = undoTrashID else { return }
    undoTrashID = nil
    guard let latest = items.first(where: { $0.id == id }), latest.isDeleted else { return }
    await trash(latest)
  }
  /// Permanently deletes every Trash entry this device may delete; shared-vault entries stay.
  @discardableResult
  func emptyTrash() async -> Int {
    let removable = TrashPlan(items: items, canEdit: canEdit).removable
    guard !busy, !removable.isEmpty else { return 0 }
    busy = true
    defer { busy = false }
    var removed = 0
    do {
      for item in removable {
        _ = try await perform(["op": .string("remove"), "id": .string(item.id)])
        removed += 1
      }
    } catch { report(error) }
    try? await refresh()
    if removed > 0 { notice = t("已永久删除 \(removed) 项", "Deleted \(removed) items permanently") }
    return removed
  }
  func remove(_ item: VaultItem) async {
    guard item.isDeleted else { return }
    do {
      _ = try await perform(["op": .string("remove"), "id": .string(item.id)])
      try await refresh()
    } catch { report(error) }
  }
  func saveSettings(_ changes: [String: JSONValue]) async {
    do {
      _ = try await perform(["op": .string("settings"), "settings": .object(changes)])
      try await refresh()
    } catch { report(error) }
  }
  func copy(_ text: String) {
    let seconds = ClipboardClear.seconds()
    var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
    if seconds > 0 { options[.expirationDate] = Date().addingTimeInterval(TimeInterval(seconds)) }
    UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: options)
    clipboardChange = UIPasteboard.general.changeCount
    notice = ClipboardClear.notice(seconds, t: t)
    activity()
  }
  func report(_ failure: Error) {
    switch failure {
    case VaultError.StaleEdit:
      error = t("此条目已在其他设备修改，草稿已保留。请对照新版本后重试。", "This entry changed on another device. Your draft is retained; review the latest version before retrying.")
    case VaultError.Authentication:
      error = t("密码不正确，或文件已损坏。", "Incorrect password or damaged file.")
    case VaultError.Locked: error = t("请先解锁资料库。", "Unlock your vault first.")
    case VaultError.InUse: error = t("资料库正在被另一进程使用，请稍后重试。", "The vault is in use. Retry shortly.")
    case VaultError.Unsupported:
      error = t(
        "此操作当前不受支持，原资料保留。",
        "This operation is not supported; existing data is preserved."
      )
    case VaultError.InvalidData: error = t("内容或文件格式无效。", "Invalid content or file format.")
    default:
      error = t("操作未完成，原有资料仍保留。请重试。", "The operation failed. Existing data is preserved; retry.")
    }
  }
}

/// Which Trash entries "Empty Trash" may delete permanently: editable entries outside shared
/// vaults. Shared-vault entries are kept and counted so the confirmation can say so.
struct TrashPlan {
  let removable: [VaultItem]
  let kept: Int
  init(items: [VaultItem], canEdit: (VaultItem) -> Bool) {
    let deleted = items.filter(\.isDeleted)
    removable = deleted.filter { canEdit($0) && $0.string("sharedVaultId").isEmpty }
    kept = deleted.count - removable.count
  }
}

/// Per-device clipboard auto-clear duration. Copies stay local-only (no Handoff); 0 means no
/// timed expiry, but locking still clears an unchanged clipboard.
enum ClipboardClear {
  static let key = "clipboardClearSeconds"
  static let options = [15, 30, 60, 120, 0]
  static func seconds(_ defaults: UserDefaults = .standard) -> Int {
    let value = defaults.object(forKey: key) as? Int ?? 30
    return options.contains(value) ? value : 30
  }
  static func label(_ seconds: Int, t: (String, String) -> String) -> String {
    switch seconds {
    case 0: return t("从不", "Never")
    case 60: return t("1 分钟", "1 minute")
    case 120: return t("2 分钟", "2 minutes")
    default: return t("\(seconds) 秒", "\(seconds) seconds")
    }
  }
  static func notice(_ seconds: Int, t: (String, String) -> String) -> String {
    seconds > 0
      ? t("已复制，\(label(seconds, t: t))后清除", "Copied; clears after \(label(seconds, t: t))")
      : t("已复制，锁定时清除", "Copied; clears when the vault locks")
  }
}

/// Tab shown after unlocking, stored per device as a `Destination` raw value.
enum StartTab {
  static let key = "startTab"
  static let options: [Destination] = [.notes, .passwords, .codes, .wallets]
  static func resolve(_ raw: String?) -> Destination {
    guard let value = Destination(rawValue: raw ?? ""), options.contains(value) else { return .notes }
    return value
  }
  static var current: Destination { resolve(UserDefaults.standard.string(forKey: key)) }
}
