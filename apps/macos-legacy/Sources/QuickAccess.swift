import AppKit
import Carbon
import Combine
import SwiftUI

enum QuickAccessSearch {
  static func website(_ item: VaultItem) -> URL? {
    let raw = item.string("website").isEmpty ? item.string("url") : item.string("website")
    return raw.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).compactMap {
      part -> URL? in
      let text = String(part)
      guard let url = URL(string: text.contains("://") ? text : "https://" + text),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
        url.user == nil, url.password == nil
      else { return nil }
      return url
    }.first
  }
  static func results(_ items: [VaultItem], query: String) -> [VaultItem] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.filter { item in
      !item.isDeleted
        && (query.isEmpty
          || [
            item.title, item.username, item.category, item.tags.joined(separator: " "),
            item.string("website"), item.string("url"),
          ].contains { $0.localizedCaseInsensitiveContains(query) })
    }.sorted { a, b in
      if a.isPinned != b.isPinned { return a.isPinned }
      if a.isFavorite != b.isFavorite { return a.isFavorite }
      let order = a.title.localizedStandardCompare(b.title)
      return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
  }
}

private final class QuickAccessPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

@MainActor
final class QuickAccessController: NSObject, ObservableObject, NSWindowDelegate {
  static let shared = QuickAccessController()
  @Published private(set) var registrationFailed = false
  private weak var store: AppStore?
  private var panel: NSPanel?
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var lockObserver: AnyCancellable?
  private var previousApplication: NSRunningApplication?
  var isPresented: Bool { panel != nil }
  var openMain: (() -> Void)?

  func attach(_ store: AppStore) {
    guard self.store !== store else { return }
    self.store = store
    lockObserver = store.$unlocked.sink { [weak self] unlocked in
      if !unlocked { self?.dismiss() }
    }
    configure()
  }

  func configure() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
      self.hotKey = nil
    }
    registrationFailed = false
    // Test hosts must not steal shortcuts from an installed application.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    let choice =
      UserDefaults.standard.string(forKey: "quickAccessShortcut") ?? "command-shift-space"
    guard choice != "disabled" else { return }
    if handler == nil {
      var spec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      let status = InstallEventHandler(
        GetApplicationEventTarget(),
        { _, event, _ in
          guard let event else { return OSStatus(eventNotHandledErr) }
          var id = EventHotKeyID()
          guard
            GetEventParameter(
              event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
              nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
            id.signature == OSType(0x5056_5141), id.id == 1
          else { return OSStatus(eventNotHandledErr) }
          DispatchQueue.main.async { QuickAccessController.shared.toggle() }
          return noErr
        }, 1, &spec, nil, &handler)
      guard status == noErr else {
        registrationFailed = true
        return
      }
    }
    let code = choice == "command-option-p" ? UInt32(kVK_ANSI_P) : UInt32(kVK_Space)
    let modifiers =
      choice == "command-option-p" ? UInt32(cmdKey | optionKey) : UInt32(cmdKey | shiftKey)
    let id = EventHotKeyID(signature: OSType(0x5056_5141), id: 1)
    registrationFailed =
      RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) != noErr
  }

  func toggle() {
    if panel != nil {
      dismiss()
      return
    }
    guard let store, store.unlocked else {
      openMain?()
      return
    }
    previousApplication = NSWorkspace.shared.frontmostApplication
    store.recordBrowserActivity()
    let panel = QuickAccessPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    panel.title = store.t("快速访问", "Quick Access")
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.hidesOnDeactivate = true
    panel.delegate = self
    panel.contentView = NSHostingView(rootView: QuickAccessView().environmentObject(store))
    self.panel = panel
    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }
  func dismiss(restoreFocus: Bool = true) {
    guard let panel else { return }
    self.panel = nil
    panel.delegate = nil
    panel.orderOut(nil)
    panel.contentView = nil
    panel.close()
    let previous = previousApplication
    previousApplication = nil
    if restoreFocus, previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      previous?.activate(options: [])
    }
  }
  func windowDidResignKey(_ notification: Notification) { dismiss() }
  func windowWillClose(_ notification: Notification) { dismiss() }
  func showItem(_ item: VaultItem) {
    guard let store, store.unlocked, !item.isDeleted else { return }
    dismiss(restoreFocus: false)
    let destination = Destination.allCases.first { $0.itemType == item.type } ?? .notes
    store.navigate(destination)
    store.selectedID = item.id
    openMain?()
  }
}

struct QuickAccessView: View {
  @EnvironmentObject private var store: AppStore
  @State private var query = ""
  @State private var selection: String?
  @State private var message: String?
  @FocusState private var focused: Bool
  private var items: [VaultItem] {
    Array(QuickAccessSearch.results(store.items, query: query).prefix(100))
  }
  private var selected: VaultItem? { items.first { $0.id == selection } ?? items.first }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField(
        store.t("搜索标题、用户名、标签或网址", "Search titles, usernames, tags or websites"), text: $query
      )
      .textFieldStyle(.roundedBorder).focused($focused).onSubmit {
        if let selected { QuickAccessController.shared.showItem(selected) }
      }
      List(selection: $selection) {
        ForEach(items) { item in
          HStack {
            VStack(alignment: .leading) {
              Text(item.title)
              Text(item.username).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isFavorite { Image(systemName: "star.fill").foregroundStyle(.secondary) }
          }.tag(item.id)
        }
      }
      if let message { Text(message).foregroundStyle(.red).font(.caption) }
      if let selected {
        HStack {
          Button(store.t("打开条目", "Open item")) { QuickAccessController.shared.showItem(selected) }
          if !selected.username.isEmpty {
            Button(store.t("复制用户名", "Copy username")) { copy(selected.username) }
          }
          if !selected.password.isEmpty {
            Button(store.t("复制密码", "Copy password")) { copy(selected.password) }
          }
          if selected.type == "totp" {
            Button(store.t("复制验证码", "Copy code")) { Task { await copyCode(selected) } }
          }
          if let url = QuickAccessSearch.website(selected) {
            Button(store.t("打开网站", "Open website")) {
              guard store.unlocked else { return }
              QuickAccessController.shared.dismiss()
              NSWorkspace.shared.open(url)
            }
          }
        }.controlSize(.small)
      }
    }.padding(20).frame(width: 620, height: 460)
      .onAppear { focused = true }
      .onChange(of: query) { _ in
        selection = nil
        store.recordBrowserActivity()
      }
      .onExitCommand { QuickAccessController.shared.dismiss() }
      .onMoveCommand { direction in
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selection } ?? -1
        if direction == .down { selection = items[min(index + 1, items.count - 1)].id }
        if direction == .up { selection = items[max(index - 1, 0)].id }
      }
  }
  private func copy(_ text: String) {
    guard store.unlocked else { return }
    store.recordBrowserActivity()
    store.copy(text)
    QuickAccessController.shared.dismiss()
  }
  private func copyCode(_ item: VaultItem) async {
    do {
      let result = try await store.perform([
        "op": .string("totp"), "secret": .string(item.string("secret")),
        "period": .number(item.number("period", fallback: 30)),
        "time": .number(Date().timeIntervalSince1970.rounded(.down)),
      ])
      if let code = result.object["code"]?.string { copy(code) }
    } catch { message = store.errorMessage(error, context: .save) }
  }
}

struct QuickAccessSettings: View {
  @EnvironmentObject private var store: AppStore
  @AppStorage("quickAccessShortcut") private var shortcut = "command-shift-space"
  @ObservedObject private var controller = QuickAccessController.shared
  var body: some View {
    VStack(alignment: .leading) {
      Picker(store.t("快速访问快捷键", "Quick Access shortcut"), selection: $shortcut) {
        Text("⌘⇧Space").tag("command-shift-space")
        Text("⌘⌥P").tag("command-option-p")
        Text(store.t("关闭", "Disabled")).tag("disabled")
      }.onChange(of: shortcut) { _ in controller.configure() }
      if controller.registrationFailed {
        Text(
          store.t(
            "快捷键被占用或无法注册，请选择其他组合。",
            "Shortcut unavailable or already registered. Choose another combination.")
        ).font(.caption).foregroundStyle(.orange)
      }
    }
  }
}
