import AppKit
import SwiftUI

struct SettingsNavigation: View {
  @EnvironmentObject private var store: AppStore
  private let pages = [
    ("general", "通用", "General", "gearshape"), ("security", "安全", "Security", "shield"),
    ("appearance", "外观", "Appearance", "paintbrush"), ("browser", "浏览器", "Browser", "safari"),
    ("backup", "备份与同步", "Backup & sync", "icloud"),
  ]
  var body: some View {
    VStack(spacing: 6) {
      ForEach(pages, id: \.0) { page in
        Button {
          store.settingsPage = page.0
        } label: {
          HStack(spacing: 16) {
            Image(systemName: page.3).frame(width: 22)
            Text(store.t(page.1, page.2))
            Spacer()
          }
          .font(.system(size: 16)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
          .background(
            store.settingsPage == page.0 ? Palette.selection : .clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
          .contentShape(Rectangle())
        }.buttonStyle(VaultButtonStyle(.row)).foregroundStyle(
          store.settingsPage == page.0 ? Palette.accent : .primary)
      }
    }.padding(12)
  }
}

struct SecuritySettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var changePassword = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DetailToolbar(title: store.t("设置", "Settings"))
      if store.settingsPage == "backup" {
        BackupView(compact: true)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 26) {
            Text(title).font(.system(size: 30, weight: .semibold))
            if store.settingsPage == "security" {
              securityForm
            } else if store.settingsPage == "appearance" {
              appearanceForm
            } else if store.settingsPage == "browser" {
              BrowserSettingsView()
            } else {
              generalForm
            }
          }.padding(36).frame(maxWidth: 840, alignment: .leading).frame(
            maxWidth: .infinity, alignment: .leading)
        }
      }
    }.sheet(isPresented: $changePassword) { ChangePasswordView() }
  }
  private var title: String {
    switch store.settingsPage {
    case "general": return store.t("通用", "General")
    case "appearance": return store.t("外观", "Appearance")
    case "browser": return store.t("浏览器", "Browser")
    default: return store.t("安全", "Security")
    }
  }
  private var securityForm: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(store.t("管理解锁方式与自动锁定。", "Manage unlocking and automatic locking.")).foregroundStyle(
        .secondary)
      Divider()
      Text(store.t("解锁方式", "Unlocking")).font(.headline)
      SettingsRow(
        title: store.t("主密码", "Master password"),
        subtitle: store.t("用于解锁资料库。", "Unlocks your vault.")
      ) {
        Button(store.t("修改主密码…", "Change password…")) { changePassword = true }
      }
      SettingsRow(
        title: store.t("使用 Touch ID", "Use Touch ID"),
        subtitle: store.t("仅在这台 Mac 上启用快捷解锁。", "Quick unlock on this Mac only.")
      ) {
        Toggle(
          "Touch ID",
          isOn: Binding(
            get: { store.biometricEnabled },
            set: { value in Task { await store.setBiometricEnabled(value) } })
        ).labelsHidden().toggleStyle(.switch).disabled(store.biometricBusy)
      }
      Text(
        store.t(
          "Touch ID 不可用时，仍可使用主密码。",
          "Your master password remains available if Touch ID is unavailable.")
      ).font(.caption).foregroundStyle(.secondary)
      Divider().padding(.vertical, 6)
      Text(store.t("自动锁定", "Automatic locking")).font(.headline)
      SettingsRow(
        title: store.t("闲置后锁定", "Lock when idle"),
        subtitle: store.t("在设定的时间后自动锁定资料库。", "Automatically lock after this period of inactivity.")
      ) {
        Picker(
          "Idle timeout",
          selection: Binding(
            get: { store.settings["macNeverIdleLock"]?.bool == true ? 0 : Int(store.settings["autoLockMinutes"]?.number ?? 60) },
            set: { value in
              store.settings["macNeverIdleLock"] = .bool(value == 0)
              if value > 0 { store.settings["autoLockMinutes"] = .number(Double(value)) }
              Task { await store.saveSettings() }
            })
        ) {
          Text(store.t("永不", "Never")).tag(0)
          ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { value in
            Text(value == 60 ? store.t("1 小时", "1 hour") : store.t("\(value) 分钟", "\(value) minutes")).tag(value)
          }
        }.labelsHidden().frame(width: 135)
      }
      SettingsRow(title: store.t("系统锁屏或睡眠时", "When the system locks or sleeps"), subtitle: "") {
        Text(store.t("立即锁定", "Lock immediately")).foregroundStyle(.secondary)
      }
      Divider().padding(.vertical, 6)
      Text(store.t("锁定后的显示", "While locked")).font(.headline)
      SettingsRow(
        title: store.t("笔记和账号内容", "Notes and account content"),
        subtitle: store.t("解锁后继续查看和编辑。", "Unlock to view and edit again.")
      ) { Text(store.t("全部隐藏", "Fully hidden")).foregroundStyle(.secondary) }
      Button(store.t("锁定资料库", "Lock vault"), action: store.lock).controlSize(.large)
    }
  }
  private var appearanceForm: some View {
    VStack(spacing: 24) {
      SettingsRow(title: store.t("外观", "Appearance"), subtitle: "") {
        Picker(
          "Theme",
          selection: Binding(
            get: { store.settings["theme"]?.string ?? "system" },
            set: {
              store.settings["theme"] = .string($0)
              Task { await store.saveSettings() }
            })
        ) {
          Text(store.t("跟随系统", "System")).tag("system")
          Text(store.t("浅色", "Light")).tag("light")
          Text(store.t("深色", "Dark")).tag("dark")
        }.labelsHidden().frame(width: 160)
      }
      SettingsRow(title: store.t("语言", "Language"), subtitle: "") {
        Picker("Language", selection: $store.language) {
          Text("简体中文").tag("zh")
          Text("English").tag("en")
        }.labelsHidden().frame(width: 160)
          .onChange(of: store.language) { value in
            store.settings["language"] = .string(value)
            UserDefaults.standard.set(value, forKey: "language")
            Task { await store.saveSettings() }
          }
      }
    }
  }
  private var generalForm: some View {
    VStack(alignment: .leading, spacing: 24) {
      Brand(size: 60)
      Text(store.t("原生 Mac 开发版 · 2.0.0", "Native Mac development build · 2.0.0")).foregroundStyle(
        .secondary)
      Text(
        store.t(
          "请使用测试数据验证导入与恢复。此版本尚未经过独立安全审计。",
          "Use test data to verify import and recovery. This build has not received an independent security audit."
        )
      ).fixedSize(horizontal: false, vertical: true)
      Button(store.t("打开本地数据文件夹", "Open local data folder")) {
        NSWorkspace.shared.open(store.directory)
      }
      Button(store.t("备份与导入", "Backup and import")) { store.navigate(.backups) }
    }
  }
}

struct SettingsRow<Control: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let control: () -> Control
  var body: some View {
    VStack(spacing: 16) {
      HStack(spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text(title)
          if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        Spacer()
        control()
      }
      Divider()
    }
  }
}

struct DetailToolbar: View {
  @EnvironmentObject private var store: AppStore
  let title: String
  var body: some View {
    HStack {
      Label(title, systemImage: "house").foregroundStyle(.secondary)
      Spacer()
      Button(action: store.lock) { Label(store.t("锁定", "Lock"), systemImage: "lock.fill") }
        .buttonStyle(VaultButtonStyle(.plain))
    }
    .padding(.horizontal, 36).padding(.top, 48).padding(.bottom, 22)
  }
}

private struct ChangePasswordView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var current = ""
  @State private var replacement = ""
  @State private var confirmation = ""
  @State private var busy = false
  @State private var inlineError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(store.t("修改主密码", "Change master password")).font(.title2)
      SecureField(store.t("当前主密码", "Current password"), text: $current)
      SecureField(
        store.t("新主密码（至少 10 个字符）", "New password (at least 10 characters)"), text: $replacement)
      SecureField(store.t("确认新主密码", "Confirm new password"), text: $confirmation)
      if !replacement.isEmpty && replacement.count < 10 {
        Text(store.t("新主密码至少需要 10 个字符。", "The new password needs at least 10 characters.")).font(
          .caption
        ).foregroundStyle(.secondary)
      }
      if !confirmation.isEmpty && replacement != confirmation {
        Text(store.t("两次输入的新主密码不一致。", "The new passwords do not match.")).font(.caption)
          .foregroundStyle(.red)
      }
      if let inlineError { Text(inlineError).font(.callout).foregroundStyle(.red) }
      HStack {
        Button(store.t("取消", "Cancel")) { dismiss() }
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(store.t("保存", "Save")) { Task { await change() } }.buttonStyle(
          VaultButtonStyle(.primary)
        )
        .tint(Palette.blue)
        .disabled(
          busy || current.isEmpty || replacement.count < 10 || replacement != confirmation)
      }
    }.textFieldStyle(.roundedBorder).padding(30).frame(width: 460)
  }
  private func change() async {
    busy = true
    inlineError = nil
    defer { busy = false }
    do {
      _ = try await store.perform([
        "op": .string("change-password"), "currentPassword": .string(current),
        "newPassword": .string(replacement),
      ])
      current = ""
      replacement = ""
      confirmation = ""
      dismiss()
      store.showToast(store.t("主密码已更新", "Master password updated"))
    } catch { inlineError = store.errorMessage(error, context: .changePassword) }
  }
}
