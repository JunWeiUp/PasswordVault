import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
  @EnvironmentObject private var store: AppStore
  var compact = false
  @State private var operation: BackupOperation?
  @State private var webdavPresented = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !compact { DetailToolbar(title: store.t("备份与导入", "Backups & import")) }
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text(store.t("备份与导入", "Backups & import")).font(.system(size: 30, weight: .semibold))
          Text(
            store.t(
              "加密备份包含笔记、账号、验证码、钱包和回收站记录。",
              "Encrypted backups include notes, accounts, codes, wallets, and Trash.")
          ).foregroundStyle(.secondary)
          Divider()
          SettingsRow(
            title: store.t("加密备份", "Encrypted backup"),
            subtitle: store.t(
              "使用独立备份密码保护导出文件。", "Protect the exported file with a backup passphrase.")
          ) {
            Button(store.t("导出备份…", "Export backup…")) { operation = .export }.buttonStyle(
              VaultButtonStyle(.primary)
            ).tint(Palette.blue)
          }
          SettingsRow(
            title: store.t("导入与恢复", "Import and restore"),
            subtitle: store.t(
              "支持旧版 JSON、加密备份和常见 CSV。",
              "Supports legacy JSON, encrypted backups, and common CSV files.")
          ) {
            Button(store.t("选择文件…", "Choose file…")) { pickImport() }
          }
          SettingsRow(
            title: "WebDAV", subtitle: store.t("连接你自己的备份服务器。", "Connect to your own backup server.")
          ) {
            Button(store.t("管理 WebDAV…", "Manage WebDAV…")) { webdavPresented = true }
          }
          Divider()
          Text(store.t("数据可移植性", "Data portability")).font(.headline)
          Text(
            store.t(
              "明文文件可被任何拿到文件的人读取。仅在迁移到其他工具时手动导出。",
              "Anyone with a plaintext file can read it. Export one only when needed to migrate to another tool."
            )
          ).foregroundStyle(.secondary)
          HStack {
            Button(store.t("导出明文 JSON…", "Export plaintext JSON…")) { operation = .plain("json") }
            Button(store.t("导出明文 CSV…", "Export plaintext CSV…")) { operation = .plain("csv") }
          }
        }.padding(36).frame(maxWidth: 880, alignment: .leading)
      }
    }.sheet(item: $operation) { BackupOperationView(operation: $0) }
      .sheet(isPresented: $webdavPresented) { WebDAVView() }
  }
  private func pickImport() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText, .data]
    if panel.runModal() == .OK, let url = panel.url { operation = .importFile(url) }
  }
}

enum BackupOperation: Identifiable {
  case export
  case importFile(URL)
  case plain(String)
  var id: String {
    switch self {
    case .export: return "export"
    case .importFile(let url): return url.path
    case .plain(let kind): return kind
    }
  }
}

private struct BackupOperationView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let operation: BackupOperation
  @State private var password = ""
  @State private var confirmed = false
  @State private var busy = false
  @State private var inlineError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(title).font(.title2.weight(.semibold))
      if case .importFile(let file) = operation {
        Text(file.lastPathComponent).font(.callout).textSelection(.enabled)
        Text(
          store.t(
            "合并到当前资料库：同一记录保留更新时间较新的一方，回收站状态也会合并。当前独有的记录会保留，不会整体替换资料库。",
            "Merge into this vault: keep the newer version of matching records, including their Trash status. Records unique to this vault remain; the vault is not replaced."
          )
        ).font(.callout).foregroundStyle(.secondary)
      }
      if let inlineError { Text(inlineError).font(.callout).foregroundStyle(.red) }
      if case .plain = operation {
        Text(
          store.t("导出文件将包含未加密的敏感信息。", "The export will contain unencrypted sensitive information."))
        Toggle(store.t("我了解明文文件的风险", "I understand the plaintext-file risk"), isOn: $confirmed)
      } else {
        SecureField(store.t("备份密码", "Backup passphrase"), text: $password).textFieldStyle(
          .roundedBorder)
        Text(
          store.t(
            "导出时至少 10 个字符；导入未加密文件时留空。",
            "Use at least 10 characters when exporting. Leave empty for an unencrypted import.")
        ).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button(store.t("取消", "Cancel")) { dismiss() }
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(store.t("继续", "Continue")) { Task { await execute() } }.buttonStyle(
          VaultButtonStyle(.primary)
        ).tint(Palette.blue).disabled(busy || !canContinue)
      }
    }.padding(30).frame(width: 470)
  }
  private var title: String {
    switch operation {
    case .export: return store.t("导出加密备份", "Export encrypted backup")
    case .importFile: return store.t("导入备份", "Import backup")
    case .plain: return store.t("明文导出", "Plaintext export")
    }
  }
  private var canContinue: Bool {
    switch operation {
    case .plain: return confirmed
    case .export: return password.count >= 10
    case .importFile: return true
    }
  }
  private func execute() async {
    busy = true
    inlineError = nil
    defer { busy = false }
    do {
      switch operation {
      case .importFile(let url):
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw VaultError.InvalidData }
        let content = try String(contentsOf: url, encoding: .utf8)
        let kind =
          url.lastPathComponent.hasSuffix(".csv.enc")
          ? "encrypted-csv" : (url.pathExtension.lowercased() == "csv" ? "csv" : "json")
        let result = try await store.perform([
          "op": .string("import"), "kind": .string(kind), "content": .string(content),
          "password": .string(password),
        ])
        await store.refresh()
        store.showToast(
          store.t(
            "已导入 \(Int(result.object["imported"]?.number ?? 0)) 条记录",
            "Imported \(Int(result.object["imported"]?.number ?? 0)) entries"))
      case .export:
        let result = try await store.perform([
          "op": .string("export"), "password": .string(password),
        ])
        guard
          try save(result.object["content"]?.string ?? "", name: "PasswordVault-backup.pvbackup")
        else { return }
      case .plain(let kind):
        let result = try await store.perform(["op": .string("export-plain"), "kind": .string(kind)])
        guard try save(result.object["content"]?.string ?? "", name: "PasswordVault-export.\(kind)")
        else { return }
      }
      password = ""
      dismiss()
    } catch { inlineError = store.errorMessage(error, context: .backup) }
  }
  private func save(_ text: String, name: String) throws -> Bool {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    if panel.runModal() == .OK, let url = panel.url {
      try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
      store.showToast(store.t("文件已保存", "File saved"))
      return true
    }
    return false
  }
}
