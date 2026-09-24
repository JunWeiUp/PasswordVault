import SwiftUI
import UniformTypeIdentifiers

struct EncryptedBackupDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  var data: Data
  init(data: Data = Data()) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct MobileSettingsView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var category = ""
  @State private var currentPassword = ""
  @State private var newPassword = ""
  @State private var confirmPassword = ""
  @State private var changing = false
  var body: some View {
    Form {
      Section {
        Button(store.t("立即锁定", "Lock now"), action: store.lock)
        Picker(
          store.t("空闲锁定", "Idle lock"),
          selection: Binding(
            get: { Int(store.settings["autoLockMinutes"]?.number ?? 60) },
            set: { minutes in
              Task { await store.saveSettings(["autoLockMinutes": .number(Double(minutes))]) }
            })
        ) {
          ForEach([1, 5, 15, 30, 60], id: \.self) {
            Text("\($0) \(store.t("分钟", "minutes"))").tag($0)
          }
        }
        if MobileBiometrics.available {
          Button(store.t("启用 / 更新 Face ID 或 Touch ID", "Enable / renew Face ID or Touch ID")) {
            Task { await store.enrollBiometrics() }
          }
          Button(store.t("关闭生物识别解锁", "Disable biometric unlock")) {
            MobileBiometrics.remove()
            UserDefaults.standard.set(false, forKey: "biometricEnabled")
          }
        }
        DisclosureGroup(store.t("修改主密码", "Change master password")) {
          SecureField(store.t("当前主密码", "Current password"), text: $currentPassword)
          SecureField(store.t("新主密码", "New password"), text: $newPassword)
          SecureField(store.t("确认新密码", "Confirm new password"), text: $confirmPassword)
          Button(store.t("更改密码", "Change password")) {
            changing = true
            Task {
              defer { changing = false }
              do {
                _ = try await store.perform([
                  "op": .string("change-password"), "currentPassword": .string(currentPassword),
                  "newPassword": .string(newPassword),
                ])
                MobileBiometrics.remove()
                UserDefaults.standard.set(false, forKey: "biometricEnabled")
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
                store.notice = store.t(
                  "主密码已更新，请重新启用生物识别。", "Password updated. Re-enable biometric unlock.")
              } catch { store.report(error) }
            }
          }.disabled(
            changing || newPassword.isEmpty || newPassword != confirmPassword
              || currentPassword.isEmpty)
        }
      } header: {
        Text(store.t("安全", "Security"))
      } footer: {
        Text(
          store.t(
            "切到后台时立即锁定；解锁期间，磁盘中的资料仍然加密。",
            "Locks immediately in the background. Data on disk stays encrypted while unlocked."))
      }
      Section(store.t("资料管理", "Your data")) {
        NavigationLink(store.t("备份与导入", "Backups & import")) { MobileBackupView() }
        NavigationLink(store.t("共享资料库", "Shared vaults")) { MobileSharingView(service: store.sync) }
        NavigationLink("WebDAV") { MobileWebDAVView() }
        NavigationLink(store.t("回收站", "Trash")) { MobileEntryList(destination: .trash) }
        DisclosureGroup(store.t("笔记分类", "Note categories")) {
          ForEach(store.categories, id: \.self) { name in
            HStack {
              Text(name)
              Spacer()
              Button(role: .destructive) {
                Task {
                  do {
                    _ = try await store.perform([
                      "op": .string("category-remove"), "name": .string(name),
                      "time": .string(ISO8601DateFormatter().string(from: Date())),
                    ])
                    try await store.refresh()
                  } catch { store.report(error) }
                }
              } label: {
                Image(systemName: "minus.circle")
              }.accessibilityLabel(store.t("移除分类，保留笔记", "Remove category; keep notes"))
            }
          }
          TextField(store.t("新分类", "New category"), text: $category)
          Button(store.t("添加分类", "Add category")) {
            Task {
              do {
                _ = try await store.perform([
                  "op": .string("category-add"), "name": .string(category),
                ])
                try await store.refresh()
                category = ""
              } catch { store.report(error) }
            }
          }.disabled(category.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      Section(store.t("工具", "Tools")) {
        NavigationLink(store.t("密码生成器", "Password generator")) { MobileGeneratorView() }
        NavigationLink(store.t("密码健康", "Password health")) { MobileAuditView() }
      }
      Section(store.t("外观与语言", "Appearance & language")) {
        Picker(
          store.t("主题", "Theme"),
          selection: Binding(
            get: { store.settings["theme"]?.string ?? "system" },
            set: { theme in Task { await store.saveSettings(["theme": .string(theme)]) } })
        ) {
          Text(store.t("跟随系统", "System")).tag("system")
          Text(store.t("浅色", "Light")).tag("light")
          Text(store.t("深色", "Dark")).tag("dark")
        }
        Picker("Language", selection: $store.language) {
          Text("简体中文").tag("zh")
          Text("English").tag("en")
        }.onChange(of: store.language) { UserDefaults.standard.set($0, forKey: "language") }
        LabeledContent(
          store.t("版本", "Version"),
          value:
            "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))"
        )
      }
    }.navigationTitle(store.t("设置", "Settings"))
  }
}

struct MobileBackupView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var password = ""
  @State private var importing = false
  @State private var exporting = false
  @State private var working = false
  @State private var document = EncryptedBackupDocument()
  @State private var result: String?
  var body: some View {
    Form {
      Section {
        SecureField(store.t("文件密码", "File password"), text: $password)
        Button(store.t("导出加密备份", "Export encrypted backup")) {
          Task {
            working = true
            defer { working = false }
            do {
              let value = try await store.perform([
                "op": .string("export"), "password": .string(password),
              ])
              document = .init(data: Data((value.object["content"]?.string ?? "").utf8))
              exporting = true
            } catch { store.report(error) }
          }
        }.disabled(working || password.count < 10)
        Button(store.t("选择文件并合并…", "Choose file and merge…")) { importing = true }.disabled(working)
      } footer: {
        Text(
          store.t(
            "支持加密备份、旧版 JSON 和 CSV。恢复旧版加密文件请填写当时的主密码。合并保留其他条目，同一 ID 采用较新的修改。",
            "Supports encrypted backups, legacy JSON and CSV. Use the original password for older encrypted files. Merge retains other entries and uses newer changes for matching IDs."
          ))
      }
      if let result { Section { Text(result) } }
    }
    .navigationTitle(store.t("备份与导入", "Backups & import"))
    .onChange(of: importing) { store.systemFileFlow = $0 || exporting }
    .onChange(of: exporting) { store.systemFileFlow = $0 || importing }
    .fileExporter(
      isPresented: $exporting, document: document, contentType: .data,
      defaultFilename: "PasswordVault.pvbackup"
    ) { outcome in
      document = .init()
      if case .success = outcome {
        password = ""
        result = store.t("加密备份已导出。", "Encrypted backup exported.")
      } else if case .failure(let error) = outcome {
        store.report(error)
      }
    }
    .fileImporter(
      isPresented: $importing, allowedContentTypes: [.data, .json, .commaSeparatedText],
      allowsMultipleSelection: false
    ) { outcome in
      guard case .success(let urls) = outcome, let url = urls.first else { return }
      Task {
        working = true
        defer { working = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 64 * 1024 * 1024 else { throw VaultError.InvalidData }
          let data = try Data(contentsOf: url)
          guard data.count <= 64 * 1024 * 1024, let content = String(data: data, encoding: .utf8)
          else { throw VaultError.InvalidData }
          let value = try await store.perform([
            "op": .string("import"), "content": .string(content), "password": .string(password),
            "kind": .string(url.pathExtension.lowercased() == "csv" ? "csv" : "json"),
          ])
          try await store.refresh()
          password = ""
          result =
            "\(store.t("已合并条目", "Merged entries")): \(Int(value.object["imported"]?.number ?? 0))"
        } catch { store.report(error) }
      }
    }
  }
}

struct MobileGeneratorView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var length = 20
  @State private var password = ""
  var body: some View {
    Form {
      Stepper("\(store.t("长度", "Length")): \(length)", value: $length, in: 12...128)
      Text(password).font(.body.monospaced()).textSelection(.enabled)
      Button(store.t("生成", "Generate")) { generate() }
      Button(store.t("复制", "Copy")) { store.copy(password) }.disabled(password.isEmpty)
    }.navigationTitle(store.t("密码生成器", "Password generator")).task { generate() }
  }
  private func generate() {
    Task {
      do {
        password =
          try await store.perform(["op": .string("generate"), "length": .number(Double(length))])
          .object["password"]?.string ?? ""
      } catch { store.report(error) }
    }
  }
}

struct MobileAuditView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var results: [JSONValue] = []
  var body: some View {
    List {
      ForEach(Array(results.enumerated()), id: \.offset) { _, value in
        VStack(alignment: .leading) {
          Text(value.object["title"]?.string ?? "").font(.headline)
          Text(
            [
              value.object["weak"]?.bool == true ? store.t("密码较弱", "Weak password") : "",
              value.object["reused"]?.bool == true ? store.t("密码重复", "Reused password") : "",
              value.object["expired"]?.bool == true ? store.t("密码过期", "Expired password") : "",
            ].filter { !$0.isEmpty }.joined(separator: " · ")
          ).foregroundStyle(.secondary)
        }
      }
      if results.isEmpty { Text(store.t("未发现风险条目", "No issues found")) }
    }.navigationTitle(store.t("密码健康", "Password health")).task {
      do { results = try await store.perform(["op": .string("audit")]).array } catch {
        store.report(error)
      }
    }
  }

}
