import SwiftUI
import UniformTypeIdentifiers

struct MobileRecoveryView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var key = ""
  @State private var confirmation = ""
  @State private var password = ""
  @State private var newPassword = ""
  @State private var confirmPassword = ""
  @State private var enabled = false
  @State private var generated = false
  @State private var saved = false
  @State private var working = false
  @State private var message: String?
  @State private var file: URL?
  @State private var importing = false
  @State private var exporting = false
  @State private var document = EncryptedBackupDocument()
  var body: some View {
    Form {
      Section {
        Text(
          store.t(
            "恢复密钥与完整应急备份必须分开保存。仅有密钥无法找回丢失且没有备份的数据。更换或停用密钥不会撤销旧备份。",
            "Keep the recovery key separate from the complete emergency backup. A key cannot retrieve lost data without a backup. Replacing or disabling a key does not revoke old backups."
          ))
      }
      if store.unlocked {
        Section(store.t("恢复密钥", "Recovery key")) {
          Text(enabled ? store.t("已启用", "Enabled") : store.t("未启用", "Not enabled"))
          if generated {
            Text(key).font(.body.monospaced()).textSelection(.enabled)
            Button(store.t("复制密钥", "Copy key")) { store.copy(key) }
            SecureField(store.t("再次输入完整密钥", "Confirm complete key"), text: $confirmation)
            Toggle(store.t("已在密码库之外保存密钥", "I saved the key outside the vault"), isOn: $saved)
          } else if enabled {
            SecureField(store.t("恢复密钥", "Recovery key"), text: $key)
          }
          SecureField(store.t("当前主密码", "Current master password"), text: $password)
          Button(store.t("生成 / 更换密钥", "Generate / replace key")) {
            run {
              key =
                try await store.perform(["op": .string("recovery-generate")]).object["key"]?.string
                ?? ""
              generated = true
              saved = false
              confirmation = ""
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
                password = ""
                confirmation = ""
                message = store.t(
                  "已启用，请导出完整应急备份。", "Enabled. Export a complete emergency backup now.")
              }
            }.disabled(!saved || normalized(key) != normalized(confirmation) || password.isEmpty)
          } else if enabled {
            Button(store.t("导出应急备份", "Export emergency backup")) {
              run {
                let result = try await store.perform([
                  "op": .string("recovery-export"), "key": .string(key),
                ])
                guard let content = result.object["content"]?.string else {
                  throw VaultError.InvalidData
                }
                document = .init(data: Data(content.utf8))
                exporting = true
              }
            }.disabled(key.isEmpty)
            Button(store.t("停用恢复密钥", "Disable recovery key"), role: .destructive) {
              run {
                _ = try await store.perform([
                  "op": .string("recovery-disable"), "currentPassword": .string(password),
                ])
                enabled = false
                key = ""
                password = ""
              }
            }.disabled(password.isEmpty)
          }
        }
      } else {
        Section(store.t("恢复资料库", "Recover vault")) {
          if !store.exists {
            Button(file?.lastPathComponent ?? store.t("选择应急备份", "Choose emergency backup")) {
              importing = true
            }
          }
          SecureField(store.t("恢复密钥", "Recovery key"), text: $key)
          SecureField(store.t("新主密码", "New master password"), text: $newPassword)
          SecureField(store.t("确认新主密码", "Confirm new password"), text: $confirmPassword)
          Button(store.t("恢复", "Recover")) {
            run {
              var archive: String?
              if !store.exists, let file {
                let access = file.startAccessingSecurityScopedResource()
                defer { if access { file.stopAccessingSecurityScopedResource() } }
                guard
                  (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024
                    * 1024
                else { throw VaultError.InvalidData }
                archive = try String(contentsOf: file, encoding: .utf8)
              }
              await store.recover(key: key, newPassword: newPassword, archive: archive)
              key = ""
              newPassword = ""
              confirmPassword = ""
            }
          }.disabled(
            key.isEmpty || newPassword.isEmpty || newPassword != confirmPassword
              || (!store.exists && file == nil))
        }
      }
      if let message { Section { Text(message) } }
      if working || store.busy { ProgressView() }
    }.navigationTitle(store.t("离线应急恢复", "Offline recovery"))
      .disabled(working || store.busy)
      .task {
        if store.unlocked {
          do {
            enabled =
              try await store.perform(["op": .string("recovery-status")]).object["enabled"]?.bool
              ?? false
          } catch { store.report(error) }
        }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
        if case .success(let url) = result {
          file = url
        } else if case .failure(let error) = result {
          store.report(error)
        }
      }
      .fileExporter(
        isPresented: $exporting, document: document, contentType: .data,
        defaultFilename: "PasswordVault-emergency.pvbackup"
      ) { result in
        document = .init()
        key = ""
        if case .success = result {
          message = store.t(
            "应急备份已保存，请与密钥分开存放。", "Emergency backup saved. Store it separately from the key.")
        } else if case .failure(let error) = result {
          store.report(error)
        }
      }
      .onChange(of: importing) { store.systemFileFlow = $0 || exporting }
      .onChange(of: exporting) { store.systemFileFlow = $0 || importing }
      .onChange(of: store.unlocked) { _ in clear() }
      .onDisappear {
        clear()
        store.systemFileFlow = false
      }
  }
  private func normalized(_ value: String) -> String {
    value.lowercased().filter { !$0.isWhitespace && $0 != "-" }
  }
  private func clear() {
    key = ""
    password = ""
    confirmation = ""
    newPassword = ""
    confirmPassword = ""
    document = .init()
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    guard !working else { return }
    working = true
    message = nil
    Task { @MainActor in
      defer { working = false }
      do { try await action() } catch { store.report(error) }
    }
  }
}
