import AppKit
import SwiftUI

struct RecoverySettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var enabled = false
  @State private var key = ""
  @State private var confirmation = ""
  @State private var password = ""
  @State private var savedSeparately = false
  @State private var generated = false
  @State private var busy = false
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.t("离线应急恢复", "Offline recovery")).font(.title2.bold())
      Text(
        store.t(
          "恢复密钥和完整应急备份必须分开保存。密钥不能找回丢失且没有备份的数据。重新生成或停用密钥不会撤销已导出的旧备份。",
          "Keep the recovery key separate from a complete emergency backup. A key cannot retrieve lost data without a backup. Replacing or disabling it does not revoke older exported backups."
        )
      ).foregroundStyle(.secondary)
      Text(enabled ? store.t("已启用", "Enabled") : store.t("尚未启用", "Not enabled"))
      if let message { Text(message).font(.callout).textSelection(.enabled) }
      if generated {
        Text(key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        Button(store.t("复制恢复密钥", "Copy recovery key")) { store.copy(key) }
        SecureField(store.t("再次输入完整恢复密钥", "Confirm the complete recovery key"), text: $confirmation)
        Toggle(
          store.t("已在密码库之外单独保存密钥", "I saved the key outside this vault"), isOn: $savedSeparately)
      } else if enabled {
        SecureField(store.t("恢复密钥（导出应急备份时使用）", "Recovery key for emergency export"), text: $key)
      }
      SecureField(
        store.t("当前主密码（启用或停用时使用）", "Current master password to enable or disable"), text: $password)
      HStack {
        Button(enabled ? store.t("更换密钥…", "Replace key…") : store.t("生成密钥…", "Generate key…")) {
          run {
            let result = try await store.perform(["op": .string("recovery-generate")])
            key = result.object["key"]?.string ?? ""
            confirmation = ""
            savedSeparately = false
            generated = true
          }
        }.disabled(generated)
        if generated {
          Button(store.t("确认启用", "Confirm and enable")) {
            run {
              _ = try await store.perform([
                "op": .string("recovery-enable"), "key": .string(key),
                "currentPassword": .string(password),
              ])
              enabled = true
              generated = false
              confirmation = ""
              password = ""
              message = store.t(
                "密钥已启用。请立即导出完整应急备份。", "Key enabled. Export a complete emergency backup now.")
            }
          }.disabled(
            !savedSeparately || normalized(key) != normalized(confirmation) || password.isEmpty)
        } else if enabled {
          Button(store.t("导出应急备份…", "Export emergency backup…")) {
            run {
              let result = try await store.perform([
                "op": .string("recovery-export"), "key": .string(key),
              ])
              guard store.unlocked else { throw VaultError.Locked }
              let panel = NSSavePanel()
              panel.nameFieldStringValue = "PasswordVault-emergency.pvbackup"
              guard panel.runModal() == .OK, let url = panel.url, store.unlocked else { return }
              guard let content = result.object["content"]?.string else {
                throw VaultError.InvalidData
              }
              try Data(content.utf8).write(to: url, options: [.atomic, .completeFileProtection])
              key = ""
              message = store.t(
                "应急备份已保存；请与恢复密钥分开存放。",
                "Emergency backup saved. Store it separately from the recovery key.")
            }
          }.disabled(key.isEmpty)
          Button(store.t("停用密钥", "Disable key")) {
            run {
              _ = try await store.perform([
                "op": .string("recovery-disable"), "currentPassword": .string(password),
              ])
              enabled = false
              key = ""
              password = ""
              message = store.t(
                "本机恢复密钥已停用，已导出的旧备份仍然有效。",
                "Local recovery disabled. Previously exported backups remain usable.")
            }
          }.disabled(password.isEmpty)
        }
      }
      HStack {
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(store.t("关闭", "Close")) { dismiss() }
      }
    }
    .textFieldStyle(.roundedBorder).padding(28).frame(width: 610).disabled(busy)
    .task {
      run {
        enabled =
          try await store.perform(["op": .string("recovery-status")]).object["enabled"]?.bool
          ?? false
      }
    }
    .onChange(of: store.unlocked) {
      if !$0 {
        clear()
        dismiss()
      }
    }
    .onDisappear { clear() }
  }
  private func normalized(_ value: String) -> String {
    value.lowercased().filter { !$0.isWhitespace && $0 != "-" }
  }
  private func clear() {
    key = ""
    confirmation = ""
    password = ""
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    message = nil
    Task { @MainActor in
      defer { busy = false }
      do { try await action() } catch { message = store.errorMessage(error, context: .backup) }
    }
  }
}

struct RecoveryUnlockView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @State private var password = ""
  @State private var confirmation = ""
  @State private var archive: URL?
  @State private var message: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.t("使用恢复密钥", "Use recovery key")).font(.title2.bold())
      Text(
        store.exists
          ? store.t(
            "使用事先启用的恢复密钥重设本机主密码。",
            "Reset this vault's password with its previously enabled recovery key.")
          : store.t(
            "选择完整应急备份，使用单独保存的密钥恢复为新资料库。",
            "Choose a complete emergency backup and its separately stored key to create a recovered vault."
          ))
      if !store.exists {
        Button(archive?.lastPathComponent ?? store.t("选择应急备份…", "Choose emergency backup…")) {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = false
          panel.allowsMultipleSelection = false
          if panel.runModal() == .OK { archive = panel.url }
        }
      }
      SecureField(store.t("恢复密钥", "Recovery key"), text: $key)
      SecureField(
        store.t("新主密码（至少 10 个字符）", "New master password (10+ characters)"), text: $password)
      SecureField(store.t("再次输入新主密码", "Confirm new master password"), text: $confirmation)
      if let message = message ?? store.authenticationError { Text(message).foregroundStyle(.red) }
      HStack {
        Button(store.t("取消", "Cancel")) { dismiss() }
        Spacer()
        if store.busy { ProgressView().controlSize(.small) }
        Button(store.t("恢复", "Recover")) {
          Task {
            do {
              var content: String?
              if let archive {
                let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1024 * 1024 * 1024 else { throw VaultError.InvalidData }
                content = try String(contentsOf: archive, encoding: .utf8)
              }
              await store.recover(key: key, newPassword: password, archive: content)
              if store.unlocked { dismiss() }
            } catch { message = store.errorMessage(error, context: .backup) }
          }
        }.disabled(
          key.isEmpty || password.count < 10 || password != confirmation
            || (!store.exists && archive == nil))
      }
    }.textFieldStyle(.roundedBorder).padding(28).frame(width: 480).disabled(store.busy)
      .onDisappear {
        key = ""
        password = ""
        confirmation = ""
      }
  }
}
