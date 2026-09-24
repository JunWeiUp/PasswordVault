import AppKit
import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
  @Published var ready = false
  @Published var exists = false
  @Published var unlocked = false
  @Published var busy = false
  @Published var error: String?
  @Published var authenticationError: String?
  @Published var saveFailed = false
  @Published var items: [VaultItem] = []
  @Published var settings: [String: JSONValue] = [:]
  @Published var sharedVaults: [JSONValue] = []
  @Published var sharedMembers: [JSONValue] = []
  @Published var destination: Destination = .notes
  @Published var selectedID: String?
  @Published var browserAccountAnchor: String?
  @Published var browserNavigationID = UUID()
  @Published var category: String?
  @Published var search = ""
  @Published var saving = false
  @Published var settingsPage = "security"
  @Published var toast: String?
  @Published var biometricEnabled = false
  @Published var biometricBusy = false
  @Published var editingNewNoteID: String?
  @Published var notePreviewModes: [String: Bool] = [:]
  @Published var language = UserDefaults.standard.string(forKey: "language") ?? "zh"

  let directory: URL
  private(set) var core: CoreClient?
  private var epoch = 0
  private var locking = false
  private var revisions: [String: Int] = [:]
  private var recoveryDraft: JSONValue?
  private let biometricAccount: String
  private var clipboardGeneration: Int?
  private var lastActivity = Date()
  private var pending: [String: VaultItem] = [:]
  private var noteEditors: [UUID: any NoteEditorLease] = [:]
  private var retiringEditors: [UUID: Task<Void, Never>] = [:]
  private var editorCaptureFailures: Set<String> = []
  private var editBaselines: [String: VaultItem] = [:]
  private var editTimes: [String: String] = [:]
  private var saveTask: Task<Void, Never>?
  private var lockTask: Task<Void, Never>?
  private(set) var recoveryAtRisk = false
  private var monitors: [Any] = []
  private var cancellables: Set<AnyCancellable> = []
  private var browserBridge: NativeBrowserBridge?
  private var started = false
  lazy var localSync = LocalSyncService(store: self)

  init(directory: URL) {
    self.directory = directory
    biometricAccount = BiometricStore.account(for: directory)
    biometricEnabled = UserDefaults.standard.bool(forKey: "biometricEnabled." + biometricAccount)
    if let bytes = try? Data(contentsOf: directory.appendingPathComponent("draft-recovery.json")) {
      recoveryDraft = try? JSONDecoder().decode(JSONValue.self, from: bytes)
    }
    do { core = try CoreClient(directory: directory) } catch {
      self.error =
        "无法打开资料库。请检查是否有另一个应用实例正在使用。 / Cannot open the vault; check for another running instance."
    }
    Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
      self?.checkIdleLock()
    }.store(in: &cancellables)
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: [
        .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel,
      ],
      handler: { [weak self] event in
        self?.lastActivity = Date()
        return event
      })
    {
      monitors.append(monitor)
    }
    DistributedNotificationCenter.default().publisher(
      for: NSNotification.Name("com.apple.screenIsLocked")
    )
    .receive(on: RunLoop.main).sink { [weak self] _ in self?.lock() }.store(in: &cancellables)
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
    {
      NSWorkspace.shared.notificationCenter.publisher(for: name).receive(on: RunLoop.main).sink {
        [weak self] _ in self?.lock()
      }.store(in: &cancellables)
    }
  }

  var chinese: Bool { language == "zh" }
  func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
  var selected: VaultItem? { items.first { $0.id == selectedID } }
  var categories: [String] {
    let saved = settings["noteCategories"]?.array.map(\.string) ?? []
    return Array(
      Set(
        (saved + items.filter { !$0.isDeleted && $0.type == "secureNote" }.map(\.category)).filter {
          !$0.isEmpty
        })
    ).sorted()
  }

  func addCategory(_ name: String) async throws {
    let response = try await perform(["op": .string("category-add"), "name": .string(name)])
    await refresh()
    guard unlocked else { throw VaultError.Locked }
    navigate(.notes, category: response.object["name"]?.string)
  }

  func removeCategory(_ name: String) async throws {
    // Flush pending edits before the core atomically clears category references.
    // A failed save must leave the category and the draft available for retry.
    let scheduledSave = saveTask
    scheduledSave?.cancel()
    await scheduledSave?.value
    await flushChanges()
    guard pending.isEmpty && editorCaptureFailures.isEmpty else { throw VaultError.Storage }
    _ = try await perform([
      "op": .string("category-remove"), "name": .string(name),
      "time": .string(ISO8601DateFormatter().string(from: Date())),
    ])
    await refresh()
    guard unlocked else { throw VaultError.Locked }
    navigate(.notes)
  }
  var visibleItems: [VaultItem] {
    items.filter { item in
      if destination == .trash {
        guard item.isDeleted else { return false }
      } else {
        guard !item.isDeleted, item.type == destination.itemType else { return false }
        guard category == nil || item.category == category else { return false }
      }
      let text = [
        item.title, item.username, item.note, item.string("url"), item.tags.joined(separator: " "),
      ].joined(separator: " ")
      return search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }.sorted { a, b in
      if a.isPinned != b.isPinned { return a.isPinned }
      if a.isFavorite != b.isFavorite { return a.isFavorite }
      return a.string("updatedAt") > b.string("updatedAt")
    }
  }

  func start() async {
    // Reopening a SwiftUI window reruns its task. Keep the existing bridge listener.
    guard !started else { return }
    started = true
    guard let core else {
      ready = true
      return
    }
    do {
      let status = try await core.call(["op": .string("status")])
      exists = status.object["exists"]?.bool ?? false
    } catch { report(error) }
    ready = true
    browserBridge = try? NativeBrowserBridge(store: self)
  }

  func authenticate(password: String, create: Bool) async {
    guard let core, !busy, !locking else { return }
    if create && password.count < 10 {
      authenticationError = t(
        "主密码至少需要 10 个字符。", "Use a master password with at least 10 characters.")
      return
    }
    busy = true
    error = nil
    authenticationError = nil
    let generation = epoch
    defer { busy = locking }
    do {
      _ = try await core.call([
        "op": .string(create ? "create" : "unlock"), "password": .string(password),
      ])
      guard generation == epoch else {
        _ = try? await core.call(["op": .string("lock")])
        return
      }
      await restoreDrafts()
      let doc = try await core.document()
      guard generation == epoch else { return }
      apply(doc)
      exists = true
      unlocked = true
      lastActivity = Date()
      selectedID = visibleItems.first?.id
    } catch {
      if epoch == generation { authenticationError = errorMessage(error, context: .unlock) }
    }
  }

  func unlockWithBiometrics() async {
    guard let core, !busy, !locking else { return }
    busy = true
    error = nil
    let generation = epoch
    defer { busy = locking }
    do {
      let reason = t("解锁 PasswordVault", "Unlock PasswordVault")
      let account = biometricAccount
      let key = try await Task.detached {
        try BiometricStore.unlock(reason: reason, account: account)
      }.value
      try await core.unlockBiometric(key)
      guard epoch == generation else {
        _ = try? await core.call(["op": .string("lock")])
        return
      }
      await restoreDrafts()
      let doc = try await core.document()
      guard generation == epoch else { return }
      apply(doc)
      unlocked = true
      lastActivity = Date()
      selectedID = visibleItems.first?.id
    } catch {
      self.authenticationError = (error as? KeychainFailure)?.message(chinese: chinese) ?? t(
        "Touch ID 未完成，请重试或使用主密码。", "Touch ID did not complete. Retry or use your master password.")
    }
  }

  func setBiometricEnabled(_ enabled: Bool) async {
    guard let core, unlocked, !biometricBusy else { return }
    biometricBusy = true
    defer { biometricBusy = false }
    do {
      if enabled {
        let key = try await core.biometricKey()
        let account = biometricAccount
        try await Task.detached { try BiometricStore.enroll(key: key, account: account) }.value
      } else {
        try BiometricStore.remove(account: biometricAccount)
      }
      biometricEnabled = enabled
      UserDefaults.standard.set(enabled, forKey: "biometricEnabled." + biometricAccount)
    } catch {
      self.error = (error as? KeychainFailure)?.message(chinese: chinese) ?? t(
        "无法设置 Touch ID。请确认设备支持并已登记指纹；主密码仍可使用。",
        "Cannot configure Touch ID. Check availability and enrolled fingerprints; master-password unlock remains available."
      )
    }
  }

  func lock() {
    guard !locking, unlocked || busy else { return }
    locking = true
    epoch += 1
    busy = true
    saveTask?.cancel()
    var changes = pending
    let closingEditors = noteEditors.values.map { lease in
      (lease, items.first(where: { $0.id == lease.itemID && canEdit($0) }), lease.source, lease.capture(closing: true))
    }
    noteEditors.removeAll()
    editorCaptureFailures.removeAll()
    pending.removeAll()
    revisions.removeAll()
    browserAccountAnchor = nil
    notePreviewModes.removeAll()
    editBaselines.removeAll()
    editTimes.removeAll()
    clearClipboard()
    unlocked = false
    items = []
    sharedVaults = []
    sharedMembers = []
    settings = [:]
    localSync.stop()
    selectedID = nil
    authenticationError = nil
    saveFailed = false
    search = ""
    category = nil
    toast = nil
    error = nil
    lockTask = Task {
      guard let core else {
        busy = false
        return
      }
      var editorFailed = false
      for (_, baseline, acknowledged, capture) in closingEditors {
        switch await capture.value {
        case .success(let text):
          if var item = baseline, item.note == acknowledged, text != item.note {
            item.note = text
            item.set("updatedAt", ISO8601DateFormatter().string(from: Date()))
            changes[item.id] = item
          }
        case .failure: editorFailed = true
        }
      }
      if let recovery = await core.lockWithPending(Array(changes.values)) {
        recoveryDraft = recovery
        do {
          recoveryAtRisk = true
          try JSONEncoder().encode(recovery).write(
            to: directory.appendingPathComponent("draft-recovery.json"), options: .atomic)
          recoveryAtRisk = false
        } catch {
          self.error = t(
            "部分修改暂未写入磁盘，已在内存中加密保留。请解锁后重试，暂时不要退出应用。",
            "Some changes could not reach disk and remain encrypted in memory. Unlock to retry before quitting."
          )
        }
      }
      if editorFailed {
        self.error = t("编辑器未能确认最后一次输入，已保留最近收到的内容。解锁后请检查笔记。", "The editor could not confirm its final input. The last received content was preserved; unlock and check the note.")
      }
      saving = false
      locking = false
      busy = false
    }
  }

  func finishLock() async { await lockTask?.value }

  func navigate(_ target: Destination, category: String? = nil) {
    browserAccountAnchor = nil
    destination = target
    self.category = category
    search = ""
    selectedID = visibleItems.first?.id
  }

  /// Validate website membership without requesting a password from the core.
  func openBrowserEntry(id: String, accountID: String?, origin: String) async throws -> Bool {
    guard unlocked, !id.isEmpty, id.utf8.count <= 4096,
      (accountID?.utf8.count ?? 0) <= 4096 else { return false }
    let generation = epoch
    let matches = try await perform(["op": .string("matches"), "origin": .string(origin)])
    guard matches.array.contains(where: {
      $0.object["id"]?.string == id && ($0.object["accountId"]?.string ?? "") == (accountID ?? "")
    }) else { return false }
    await refresh()
    guard generation == epoch, unlocked,
      let item = items.first(where: { $0.id == id }), !item.isDeleted,
      ["password", "totp"].contains(item.type) else { return false }
    if let accountID, !accountID.isEmpty,
       !(item.fields["accounts"]?.array ?? []).contains(where: { $0.object["id"]?.string == accountID }) { return false }
    navigate(item.type == "totp" ? .codes : .passwords)
    selectedID = id
    browserAccountAnchor = accountID.flatMap { $0.isEmpty ? nil : "account:" + $0 } ?? "entry-top"
    browserNavigationID = UUID()
    recordBrowserActivity()
    return true
  }

  func newItem() async {
    guard unlocked, let type = destination.itemType else { return }
    search = ""
    let names = ["secureNote": t("未命名笔记", "Untitled note"), "password": t("未命名账号", "Untitled account"), "totp": t("未命名验证码", "Untitled authenticator"), "crypto": t("未命名钱包", "Untitled wallet")]
    let title = names[type] ?? t("新条目", "New entry")
    var item = VaultItem.blank(type: type, title: title)
    item.category = category ?? ""
    if await save(item) {
      selectedID = item.id
      editingNewNoteID = item.id
    }
  }

  func canEdit(_ item: VaultItem) -> Bool {
    guard unlocked, !item.isDeleted else { return false }
    let vaultID = item.string("sharedVaultId")
    if vaultID.isEmpty { return true }
    let own = settings["sharingIdentity"]?.object["publicKey"]?.string ?? ""
    return !own.isEmpty && sharedMembers.contains { member in
      let fields = member.object
      return fields["vaultId"]?.string == vaultID && fields["userPublicKey"]?.string == own
        && ["owner", "editor"].contains(fields["role"]?.string ?? "")
    }
  }

  func prepareNoteEditor(_ lease: any NoteEditorLease) async -> String? {
    let generation = epoch
    for old in Array(noteEditors.values) where old.itemID == lease.itemID && old.id != lease.id {
      retireNoteEditor(old)
      await retiringEditors[old.id]?.value
    }
    guard generation == epoch, unlocked, !lease.isClosing,
      let item = items.first(where: { $0.id == lease.itemID }) else { return nil }
    noteEditors[lease.id] = lease
    return item.note
  }

  @discardableResult
  func receiveNoteEditorChange(_ lease: any NoteEditorLease, text: String) -> Bool {
    guard unlocked, noteEditors[lease.id] != nil, !lease.isClosing,
      var item = items.first(where: { $0.id == lease.itemID }), canEdit(item) else { return false }
    if item.note != text { item.note = text; editEntry(item) }
    return true
  }

  func retireNoteEditor(_ lease: any NoteEditorLease) {
    guard retiringEditors[lease.id] == nil else { return }
    guard noteEditors[lease.id] != nil else { _ = lease.capture(closing: true); return }
    let generation = epoch
    let baseline = items.first(where: { $0.id == lease.itemID })?.note
    let acknowledged = lease.source
    let capture = lease.capture(closing: true)
    retiringEditors[lease.id] = Task { [weak self] in
      guard let self else { return }
      let result = await capture.value
      defer { noteEditors.removeValue(forKey: lease.id); retiringEditors.removeValue(forKey: lease.id) }
      guard generation == epoch, unlocked else { return }
      if case .success = result { editorCaptureFailures.remove(lease.itemID) }
      if case .success(let text) = result, baseline == acknowledged,
        var item = items.first(where: { $0.id == lease.itemID }), item.note == baseline, canEdit(item), item.note != text {
        item.note = text; editEntry(item)
      } else if case .failure = result {
        editorCaptureFailures.insert(lease.itemID)
        saveFailed = true
        error = t("编辑器未能确认最后一次输入，原有笔记已保留。", "The editor could not confirm its last input. The existing note was preserved.")
      }
    }
  }

  // A source editor must not become writable until the rendered editor has
  // handed over its final DOM/composition input.
  func prepareNoteSource(_ itemID: String) async -> Bool {
    let generation = epoch
    for lease in Array(noteEditors.values) where lease.itemID == itemID {
      retireNoteEditor(lease)
      await retiringEditors[lease.id]?.value
    }
    return generation == epoch && unlocked && !editorCaptureFailures.contains(itemID)
      && items.contains(where: { $0.id == itemID && canEdit($0) })
  }

  private func flushNoteEditors() async {
    let generation = epoch
    for task in Array(retiringEditors.values) { await task.value }
    for lease in Array(noteEditors.values) where !lease.isClosing {
      let baseline = items.first(where: { $0.id == lease.itemID })?.note
      let acknowledged = lease.source
      let result = await lease.capture(closing: false).value
      guard generation == epoch, unlocked else { return }
      if case .success = result { editorCaptureFailures.remove(lease.itemID) }
      if case .success(let text) = result, baseline == acknowledged,
        var item = items.first(where: { $0.id == lease.itemID }), item.note == baseline, canEdit(item), item.note != text {
        item.note = text; editEntry(item)
      } else if case .failure = result { editorCaptureFailures.insert(lease.itemID); saveFailed = true }
    }
  }

  func editNote(_ item: VaultItem) {
    editEntry(item)
  }

  func endEntryEditing(_ id: String) {
    editBaselines.removeValue(forKey: id)
    editTimes.removeValue(forKey: id)
  }

  func normalizeEntryAccounts(_ id: String) {
    guard let item = items.first(where: { $0.id == id }), canEdit(item) else { return }
    let normalized = EntryPasswordHistory.normalizeAccountIDs(item)
    guard normalized != item else { return }
    endEntryEditing(id)
    replace(normalized)
    editEntry(normalized)
  }

  func editEntry(_ item: VaultItem) {
    guard canEdit(item) else { return }
    if let existing = items.first(where: { $0.id == item.id }), !canEdit(existing) { return }
    var updated = item
    if ["password", "totp"].contains(item.type) {
      if editBaselines[item.id] == nil {
        editBaselines[item.id] = items.first(where: { $0.id == item.id }) ?? item
        editTimes[item.id] = ISO8601DateFormatter().string(from: Date())
      }
      updated = EntryPasswordHistory.prepare(item, baseline: editBaselines[item.id], changedAt: editTimes[item.id]!)
    }
    updated.set("updatedAt", ISO8601DateFormatter().string(from: Date()))
    replace(updated)
    pending[updated.id] = updated
    revisions[updated.id, default: 0] += 1
    saving = true
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled else { return }
      await flushChanges()
    }
  }

  func flushChanges(excluding excludedID: String? = nil) async {
    guard let core, unlocked else { return }
    let generation = epoch
    await flushNoteEditors()
    guard generation == epoch, unlocked else { return }
    let changes = pending.values.filter { $0.id != excludedID }.map {
      ($0, revisions[$0.id, default: 0])
    }
    for (item, revision) in changes {
      do {
        _ = try await core.call(["op": .string("save"), "item": try .from(item)])
        guard generation == epoch else { return }
        if revisions[item.id] == revision { pending.removeValue(forKey: item.id) }
      } catch { if generation == epoch { saveFailed = true } }
    }
    saving = !pending.isEmpty
    if pending.isEmpty { saveFailed = !editorCaptureFailures.isEmpty }
  }

  @discardableResult
  func save(_ item: VaultItem) async -> Bool {
    do {
      try await saveRecord(item)
      return true
    } catch {
      report(error, context: .save)
      return false
    }
  }

  func saveRecord(_ item: VaultItem) async throws {
    guard let core, unlocked else { throw VaultError.Locked }
    let originalNote = items.first(where: { $0.id == item.id })?.note
    let scheduledSave = saveTask
    scheduledSave?.cancel()
    await scheduledSave?.value
    await flushChanges(excluding: item.id)
    let generation = epoch
    revisions[item.id, default: 0] += 1
    let revision = revisions[item.id]!
    var updated = item
    if item.type == "secureNote", item.note == originalNote, let latest = items.first(where: { $0.id == item.id }) { updated.note = latest.note }
    updated.set("updatedAt", ISO8601DateFormatter().string(from: Date()))
    _ = try await core.call(["op": .string("save"), "item": try .from(updated)])
    guard generation == epoch else { throw VaultError.Locked }
    if revisions[item.id] == revision {
      replace(updated)
      pending.removeValue(forKey: item.id)
    }
    saving = !pending.isEmpty
    if pending.isEmpty { saveFailed = !editorCaptureFailures.isEmpty }
  }

  func prepareSnapshot() async throws {
    let scheduledSave = saveTask
    scheduledSave?.cancel()
    await scheduledSave?.value
    await flushChanges()
    guard unlocked else { throw VaultError.Locked }
    guard pending.isEmpty && editorCaptureFailures.isEmpty else { throw VaultError.Storage }
  }

  private func restoreDrafts() async {
    guard let core, let recovery = recoveryDraft else { return }
    do {
      _ = try await core.call([
        "op": .string("restore-drafts"), "payload": recovery.object["payload"] ?? .null,
      ])
      recoveryDraft = nil
      recoveryAtRisk = false
      try? FileManager.default.removeItem(
        at: directory.appendingPathComponent("draft-recovery.json"))
    } catch {
      self.error = t(
        "待恢复的修改仍保留在加密草稿中，请检查存储权限后重新解锁。",
        "Unsaved changes remain in an encrypted recovery draft. Check storage permissions and unlock again."
      )
    }
  }

  func toggleFavorite(_ id: String) async {
    guard var item = items.first(where: { $0.id == id }) else { return }
    item.isFavorite.toggle()
    _ = await save(item)
  }

  func togglePin(_ id: String) async {
    guard var item = items.first(where: { $0.id == id }) else { return }
    item.isPinned.toggle()
    _ = await save(item)
  }

  func trash(_ item: VaultItem) async {
    var changed = items.first(where: { $0.id == item.id }) ?? item
    changed.isDeleted = !item.isDeleted
    changed.set("deletedAt", item.isDeleted ? "" : ISO8601DateFormatter().string(from: Date()))
    if await save(changed) {
      if item.isDeleted {
        destination = Destination.allCases.first(where: { $0.itemType == item.type }) ?? .notes
        category = nil
        search = ""
        selectedID = item.id
        showToast(t("已恢复条目", "Entry restored"))
      } else {
        selectedID = visibleItems.first?.id
        showToast(t("已移到回收站，可随时恢复", "Moved to Trash; you can restore it later"))
      }
    }
  }

  func removePermanently(_ item: VaultItem) async {
    guard let core, unlocked else { return }
    do {
      _ = try await core.call(["op": .string("remove"), "id": .string(item.id)])
      items.removeAll { $0.id == item.id }
      selectedID = visibleItems.first?.id
      showToast(t("条目已永久删除", "Entry permanently deleted"))
    } catch { report(error) }
  }

  @discardableResult
  func saveSettings() async -> Bool {
    guard let core, unlocked else { return false }
    do {
      _ = try await core.call(["op": .string("settings"), "settings": .object(settings)])
      return true
    } catch {
      if let persisted = try? await core.document(), unlocked {
        settings = persisted.settings
        if let chosen = settings["language"]?.string { language = chosen }
      }
      report(error, context: .save)
      return false
    }
  }

  func perform(_ request: [String: JSONValue]) async throws -> JSONValue {
    guard let core, unlocked else { throw VaultError.Locked }
    if ["export", "export-plain", "import"].contains(request["op"]?.string ?? "") {
      try await prepareSnapshot()
    }
    let generation = epoch
    let response = try await core.call(request)
    guard generation == epoch, unlocked else { throw VaultError.Locked }
    return response
  }

  func refresh() async {
    guard let core, unlocked else { return }
    let generation = epoch
    do {
      let doc = try await core.document()
      if epoch == generation {
        apply(doc)
        for item in pending.values { replace(item) }
        if !visibleItems.contains(where: { $0.id == selectedID }) {
          selectedID = visibleItems.first?.id
        }
      }
    } catch { report(error) }
  }

  func copy(_ text: String) {
    guard unlocked else { return }
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(text, forType: .string) {
      clipboardGeneration = NSPasteboard.general.changeCount
      let generation = clipboardGeneration
      Task {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        if clipboardGeneration == generation { clearClipboard() }
      }
      showToast(t("已复制", "Copied"))
    } else {
      error = t("复制失败，请重试。", "Could not copy. Please retry.")
    }
  }

  private func clearClipboard() {
    if let generation = clipboardGeneration, NSPasteboard.general.changeCount == generation {
      NSPasteboard.general.clearContents()
    }
    clipboardGeneration = nil
  }

  func showToast(_ value: String) {
    toast = value
    Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      if toast == value { toast = nil }
    }
  }

  func report(_ error: Error, context: ErrorContext = .general) {
    self.error = errorMessage(error, context: context)
  }

  private func apply(_ doc: VaultDocument) {
    for incoming in doc.items where pending[incoming.id] == nil {
      if let current = items.first(where: { $0.id == incoming.id }),
         EntryPasswordHistory.credentialState(current) != EntryPasswordHistory.credentialState(incoming) {
        endEntryEditing(incoming.id)
      }
    }
    items = doc.items
    settings = doc.settings
    sharedVaults = doc.sharedVaults
    sharedMembers = doc.sharedMembers
    if let chosen = settings["language"]?.string, ["zh", "en"].contains(chosen) {
      language = chosen
    }
  }
  private func replace(_ item: VaultItem) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
    }
  }
  func checkIdleLock(now: Date = Date()) {
    guard unlocked else { return }
    let configured = settings["autoLockMinutes"]?.number ?? 60
    guard settings["macNeverIdleLock"]?.bool != true else { return }
    let minutes = max(1, configured)
    if now.timeIntervalSince(lastActivity) >= minutes * 60 { lock() }
  }

  func recordBrowserActivity(now: Date = Date()) {
    if unlocked { lastActivity = now }
  }
}
