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
  var body: some View {
    Form {
      Section(store.t("资料", "Library")) {
        NavigationLink(store.t("全部项目", "All items")) { MobileEntryList(destination: .all) }
        NavigationLink(store.t("个人收藏", "Favorites")) { MobileEntryList(destination: .favorites) }
        NavigationLink(store.t("回收站", "Trash")) { MobileEntryList(destination: .trash) }
        NavigationLink(store.t("笔记分类", "Note categories")) { MobileCategorySettings() }
      }
      Section(store.t("设置", "Settings")) {
        NavigationLink(store.t("通用", "General")) { MobileGeneralSettings() }
        NavigationLink(store.t("安全", "Security")) { MobileSecuritySettings() }
        NavigationLink(store.t("自动填充与通行密钥", "AutoFill & passkeys")) { MobileAutofillSettings() }
        NavigationLink(store.t("同步与设备", "Sync & devices")) {
          ScrollView { RelaySettingsView(relay: store.relay, t: store.t).padding() }
            .navigationTitle(store.t("同步与设备", "Sync & devices"))
        }
        NavigationLink(store.t("备份与导入", "Backups & import")) { MobileBackupSettings() }
      }
      Section(store.t("工具", "Tools")) {
        NavigationLink(store.t("密码生成器", "Password generator")) { MobileGeneratorView() }
        NavigationLink(store.t("密码健康", "Password health")) { MobileAuditView() }
        NavigationLink(store.t("安全中心", "Security center")) { MobileSecurityCenter() }
      }
      Section {
        NavigationLink(store.t("关于", "About")) { MobileAboutView() }
        Button(store.t("立即锁定", "Lock now"), action: store.lock)
      }
    }.navigationTitle(store.t("设置", "Settings"))
  }
}

struct MobileGeneralSettings: View {
  @EnvironmentObject private var store: MobileVaultStore
  @AppStorage(StartTab.key) private var startTab = Destination.notes.rawValue
  @AppStorage(ClipboardClear.key) private var clipboardSeconds = 30
  var body: some View {
    Form {
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
      }
      Section {
        Picker(store.t("打开时显示", "Open to"), selection: $startTab) {
          ForEach(StartTab.options) { Text($0.title(chinese: store.chinese)).tag($0.rawValue) }
        }
      } header: {
        Text(store.t("启动", "Startup"))
      } footer: {
        Text(store.t("解锁后先显示这个页面。仅保存在本机。", "Shown first after unlocking. Saved on this device only."))
      }
      Section {
        Picker(store.t("自动清除剪贴板", "Clear clipboard"), selection: $clipboardSeconds) {
          ForEach(ClipboardClear.options, id: \.self) { Text(ClipboardClear.label($0, t: store.t)).tag($0) }
        }
      } header: {
        Text(store.t("剪贴板", "Clipboard"))
      } footer: {
        Text(store.t(
          "复制的内容只留在本机，不会通过“通用剪贴板”同步到其他设备。锁定时，如剪贴板未被替换也会清除。",
          "Copies stay on this device and are not shared through Universal Clipboard. Locking also clears the clipboard if it was not replaced."))
      }
    }.navigationTitle(store.t("通用", "General"))
  }
}

struct MobileSecuritySettings: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var currentPassword = ""
  @State private var newPassword = ""
  @State private var confirmPassword = ""
  @State private var changing = false
  var body: some View {
    Form {
      Section {
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
      } footer: {
        Text(
          store.t(
            "切到后台时立即锁定；解锁期间，磁盘中的资料仍然加密。",
            "Locks immediately in the background. Data on disk stays encrypted while unlocked."))
      }
      Section {
        NavigationLink(store.t("应急恢复", "Emergency recovery")) { MobileRecoveryView() }
      }
    }.navigationTitle(store.t("安全", "Security"))
  }
}

struct MobileCategorySettings: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var category = ""
  var body: some View {
    Form {
      Section(footer: Text(store.t("移除分类只会清空笔记的归类，不会删除笔记。", "Removing a category only clears it from notes; notes are kept."))) {
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
    }.navigationTitle(store.t("笔记分类", "Note categories"))
  }
}

struct MobileBackupSettings: View {
  @EnvironmentObject private var store: MobileVaultStore
  var body: some View {
    Form {
      Section {
        NavigationLink(store.t("加密备份", "Encrypted backups")) { MobileBackupView() }
        NavigationLink("WebDAV") { MobileWebDAVView() }
        NavigationLink(store.t("迁入 CSV / 1Password .1pux", "Import CSV / 1Password .1pux")) {
          ImportReviewView(perform: { request in let result = try await store.perform(request); if request["op"]?.string == "import-commit" { try await store.refresh() }; return result }, t: store.t)
        }
      }
    }.navigationTitle(store.t("备份与导入", "Backups & import"))
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
  @State private var options = GeneratorOptions()
  @State private var password = ""
  var body: some View {
    Form {
      Section {
        Text(password.isEmpty ? " " : password).font(.title3.monospaced()).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("generator.output")
        HStack {
          Button(store.t("重新生成", "Regenerate")) { generate() }
          Spacer()
          Button(store.t("复制", "Copy")) { store.copy(password) }.disabled(password.isEmpty)
        }.buttonStyle(.borderless)
      }
      Section {
        VStack(alignment: .leading) {
          Text("\(store.t("长度", "Length")): \(options.length)")
          Slider(value: Binding(get: { Double(options.length) }, set: { options.length = Int($0.rounded()) }),
            in: Double(GeneratorOptions.lengths.lowerBound)...Double(GeneratorOptions.lengths.upperBound), step: 1)
            .accessibilityLabel(store.t("密码长度", "Password length"))
        }
        Toggle(store.t("大写字母 A–Z", "Uppercase A–Z"), isOn: $options.upper)
        Toggle(store.t("小写字母 a–z", "Lowercase a–z"), isOn: $options.lower)
        Toggle(store.t("数字 0–9", "Digits 0–9"), isOn: $options.digits)
        Toggle(store.t("符号 !@#…", "Symbols !@#…"), isOn: $options.symbols)
      } header: {
        Text(store.t("规则", "Rules"))
      } footer: {
        Text(options.valid
          ? store.t("在本机生成，范围 4–64；规则由加密核心再次校验，不保存生成历史。单词组合暂未支持。", "Generated on this device, 4–64 characters; the core validates the rules again. No history is kept. Passphrases are not supported yet.")
          : store.t("至少选择一种字符类型。", "Choose at least one character type."))
      }
    }
    .navigationTitle(store.t("密码生成器", "Password generator"))
    .task { generate() }
    .onChange(of: options) { _ in generate() }
  }
  private func generate() {
    guard options.valid else { password = ""; return }
    let request = options.request
    Task {
      do {
        let value = try await store.perform(request).object["password"]?.string ?? ""
        if request == options.request { password = value }
      } catch { store.report(error) }
    }
  }
}

/// Generator rules sent to the core `generate` op, which enforces 4–128 and at least one class.
struct GeneratorOptions: Equatable {
  static let lengths = 4...64
  var length = 20 { didSet { length = min(max(length, Self.lengths.lowerBound), Self.lengths.upperBound) } }
  var upper = true
  var lower = true
  var digits = true
  var symbols = true
  var valid: Bool { upper || lower || digits || symbols }
  var request: [String: JSONValue] {
    ["op": .string("generate"), "length": .number(Double(length)), "upper": .bool(upper),
     "lower": .bool(lower), "digits": .bool(digits), "symbols": .bool(symbols)]
  }
}

/// Password health filters over the core `audit` results (weak, reused, expired).
enum AuditFilter: String, CaseIterable, Identifiable {
  case weak, reused, expired
  var id: String { rawValue }
  func matches(_ result: JSONValue) -> Bool { result.object[rawValue]?.bool == true }
  func label(_ t: (String, String) -> String) -> String {
    switch self {
    case .weak: return t("弱密码", "Weak")
    case .reused: return t("重复使用", "Reused")
    case .expired: return t("需要更换", "Due for change")
    }
  }
  static func filtered(_ results: [JSONValue], by filter: AuditFilter?) -> [JSONValue] {
    guard let filter else { return results }
    return results.filter(filter.matches)
  }
}

struct MobileAuditView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var results: [JSONValue] = []
  @State private var filter: AuditFilter?
  @State private var breachCheck = false
  @State private var selected: VaultItem?
  var body: some View {
    List {
      Section {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
          ForEach(AuditFilter.allCases) { kind in
            Button { filter = filter == kind ? nil : kind } label: {
              card(kind.label(store.t), "\(results.filter(kind.matches).count)", selected: filter == kind)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("health.\(kind.rawValue)")
            .accessibilityAddTraits(filter == kind ? .isSelected : [])
          }
          Button { breachCheck = true } label: {
            card(store.t("已知泄露", "Known breaches"), store.t("检查", "Check"), selected: false)
          }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("health.breach")
          .accessibilityHint(store.t("在安全中心联网检查；不会自动联网。", "Checks online in the Security center; never automatic."))
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
      } footer: {
        Text(store.t(
          "检查弱密码、重复使用和到期需要更换的密码。这不是对应用本身的安全审计。",
          "Checks weak, reused and expired passwords. This is not a security audit of the app itself."))
      }
      Section(filter.map { $0.label(store.t) } ?? store.t("需要处理", "Needs attention")) {
        let shown = AuditFilter.filtered(results, by: filter)
        ForEach(Array(shown.enumerated()), id: \.offset) { _, value in
          Button { selected = store.items.first { $0.id == value.object["id"]?.string } } label: {
            VStack(alignment: .leading) {
              Text(value.object["title"]?.string ?? "").font(.headline).foregroundStyle(Color(uiColor: .label))
              Text(
                AuditFilter.allCases.filter { $0.matches(value) }.map { $0.label(store.t) }
                  .joined(separator: " · ")
              ).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
          }
        }
        if shown.isEmpty { Text(store.t("未发现风险条目", "No issues found")) }
      }
    }
    .navigationTitle(store.t("密码健康", "Password health"))
    .navigationDestination(isPresented: $breachCheck) { MobileSecurityCenter() }
    .sheet(item: $selected) { item in NavigationStack { MobileEntryDetail(id: item.id) } }
    .task(id: store.items) {
      do { results = try await store.perform(["op": .string("audit")]).array } catch {
        store.report(error)
      }
    }
  }
  private func card(_ title: String, _ value: String, selected: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(value).font(.title2.bold()).foregroundStyle(selected ? Color.accentColor : Color(uiColor: .label))
      Text(title).font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(
      selected ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

private struct MobileSecurityCenter: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var selected: VaultItem?
  var body: some View {
    SecurityCenterView(items: store.items, perform: store.perform, t: store.t, openItem: { id in selected = store.items.first { $0.id == id } })
      .navigationTitle(store.t("安全中心", "Security center"))
      .sheet(item: $selected) { item in NavigationStack { MobileEntryDetail(id: item.id) } }
  }
}
