import AppKit
import SwiftUI

@main
struct PasswordVaultApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var store: AppStore
  @Environment(\.openWindow) private var openWindow

  init() {
    let args = ProcessInfo.processInfo.arguments
    let directory: URL
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PasswordVault-test-host-" + UUID().uuidString)
    } else if let index = args.firstIndex(of: "--vault-directory"), args.indices.contains(index + 1)
    {
      directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
    } else {
      directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
        0
      ]
      .appendingPathComponent("PasswordVaultNative", isDirectory: true)
    }
    _store = StateObject(wrappedValue: AppStore(directory: directory))
  }

  var body: some Scene {
    // A primary Window scene exits on close; WindowGroup keeps the app and bridge alive.
    WindowGroup("PasswordVault", id: "main") {
      RootView().environmentObject(store)
        .frame(minWidth: 1000, minHeight: 680)
        .tint(Palette.accent)
        .preferredColorScheme(colorScheme)
        .task {
          delegate.store = store
          QuickAccessController.shared.openMain = {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
          }
          QuickAccessController.shared.attach(store)
          await store.start()
        }
    }
    .defaultSize(width: 1440, height: 960)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button(store.t("新建条目", "New entry")) { Task { await store.newItem() } }
          .keyboardShortcut("n").disabled(!store.unlocked || store.destination.itemType == nil)
      }
      CommandMenu(store.t("资料库", "Vault")) {
        Button(store.t("快速访问", "Quick Access")) { QuickAccessController.shared.toggle() }
        Button(store.t("搜索", "Search")) {
          NotificationCenter.default.post(name: .focusVaultSearch, object: nil)
        }
        .keyboardShortcut("k").disabled(!store.unlocked)
        Button(store.t("锁定资料库", "Lock vault"), action: store.lock)
          .keyboardShortcut("l").disabled(!store.unlocked)
        Divider()
        Button(store.t("设置", "Settings")) { store.navigate(.settings) }
          .keyboardShortcut(",").disabled(!store.unlocked)
      }
    }
  }

  private var colorScheme: ColorScheme? {
    switch store.settings["theme"]?.string {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var store: AppStore?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store else { return .terminateNow }
    Task {
      await store.flushChanges()
      store.lock()
      await store.finishLock()
      sender.reply(toApplicationShouldTerminate: !store.recoveryAtRisk)
    }
    return .terminateLater
  }
}

extension Notification.Name {
  static let focusVaultSearch = Notification.Name("PasswordVault.focusSearch")
}

enum Palette {
  static let blue = Color(red: 0.19, green: 0.36, blue: 0.91)
  static let accent = Color(
    nsColor: NSColor(name: "VaultAccent") { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.45, green: 0.66, blue: 1, alpha: 1)
        : NSColor(calibratedRed: 0.19, green: 0.36, blue: 0.91, alpha: 1)
    })
  static let sidebar = Color(
    nsColor: NSColor(name: "VaultSidebar") { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.13, alpha: 1)
        : NSColor(calibratedWhite: 0.955, alpha: 1)
    })
  static let surface = Color(nsColor: .textBackgroundColor)
  static let selection = blue.opacity(0.12)
  static let divider = Color.primary.opacity(0.10)
}

struct RootView: View {
  @EnvironmentObject private var store: AppStore
  var body: some View {
    Group {
      // Removing the entire unlocked hierarchy also drops editors and undo state.
      if store.unlocked { WorkspaceView() } else { UnlockView() }
    }
    .buttonStyle(VaultButtonStyle())
    .overlay(alignment: .bottom) {
      if let text = store.toast {
        Label(text, systemImage: "checkmark.circle.fill")
          .padding(.horizontal, 18).padding(.vertical, 10)
          .background(.regularMaterial, in: Capsule()).padding(22)
      }
    }
    .safeAreaInset(edge: .top) {
      if store.unlocked && store.recoveryReviewPending {
        HStack {
          Text(store.t("有加密恢复草稿待审核，编辑暂时停用。", "Encrypted recovery drafts need review; editing is paused."))
          Spacer()
          Button(store.t("审核草稿", "Review drafts")) { Task { await store.openRecoveryReview() } }
        }.padding(12).background(.regularMaterial)
      }
    }
    .sheet(isPresented: Binding(get: { store.unlocked && store.recoveryReviewPresented }, set: { store.recoveryReviewPresented = $0 })) { if store.unlocked { RecoveryDraftReviewView().environmentObject(store) } }
    .alert(
      store.t("操作未完成", "Could not complete"),
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button(store.t("好", "OK")) { store.error = nil }
    } message: {
      Text(store.error ?? "")
    }
  }
}

struct Brand: View {
  var size: CGFloat = 36
  var showName = true
  var body: some View {
    HStack(spacing: 12) {
      Image("BrandMark").resizable().interpolation(.high).frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
      if showName {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 6) { name; version }
          VStack(alignment: .leading, spacing: 2) { name; version }
        }
      }
    }
  }
  private var name: some View {
    Text("PasswordVault").font(.system(size: 17, weight: .semibold)).fixedSize()
  }
  @ViewBuilder private var version: some View {
    if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
      Text("v\(value)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .fixedSize().accessibilityIdentifier("app-version")
    }
  }
}

struct EmptyState: View {
  let symbol: String
  let title: String
  let message: String
  var fillsSpace = true
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
      Text(title).font(.title3.weight(.semibold))
      Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(
        maxWidth: 360)
    }.frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil).padding(
      fillsSpace ? 36 : 16)
  }
}
