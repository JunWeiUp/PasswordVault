import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class MobileVaultStore: ObservableObject {
  @Published var recoveredDraft: VaultItem?
  private var volatileRecovery: JSONValue?
  var pendingDraft: VaultItem?
  var systemFileFlow = false
  @Published var unlocked = false
  @Published var exists = false
  @Published var legacyAvailable = false
  private var legacySource: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("db.sqlite")
  }
  @Published var ready = false
  @Published var busy = false
  @Published var items: [VaultItem] = []
  @Published var sharedVaults: [JSONValue] = []
  @Published var sharedMembers: [JSONValue] = []
  lazy var sync = MobileLocalSyncService(store: self)
  @Published var settings: [String: JSONValue] = [:]
  @Published var error: String?
  @Published var notice: String?
  @Published var language = UserDefaults.standard.string(forKey: "language") ?? "zh"
  let directory: URL
  private var core: MobileCore?
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
  func canEdit(_ item: VaultItem) -> Bool {
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
      sharedVaults = document.sharedVaults
      sharedMembers = document.sharedMembers
      exists = true
      legacyAvailable = false
      unlocked = true
      activity()
      await recoverDraft(core)
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
      sharedVaults = document.sharedVaults
      sharedMembers = document.sharedMembers
      exists = true
      legacyAvailable = false
      unlocked = true
      activity()
    } catch { report(error) }
  }
  func lock() {
    sync.stop()
    sharedVaults = []
    sharedMembers = []
    epoch += 1
    unlocked = false
    items = []
    settings = [:]
    notice = nil
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
      sharedVaults = document.sharedVaults
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
    sharedVaults = document.sharedVaults
    sharedMembers = document.sharedMembers
  }
  @discardableResult
  func save(_ item: VaultItem) async -> Bool {
    guard !busy else { return false }
    busy = true
    defer { busy = false }
    do {
      var item = item
      item.set("updatedAt", ISO8601DateFormatter().string(from: Date()))
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
      notice = latest.isDeleted ? t("已移到回收站", "Moved to Trash") : t("已恢复", "Restored")
      return true
    }
    return false
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
    UIPasteboard.general.setItems(
      [[UTType.utf8PlainText.identifier: text]],
      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)])
    clipboardChange = UIPasteboard.general.changeCount
    notice = t("已复制，30 秒后清除", "Copied; clears after 30 seconds")
    activity()
  }
  func report(_ failure: Error) {
    switch failure {
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
