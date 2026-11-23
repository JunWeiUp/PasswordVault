import SwiftUI

struct MobileWebDAVView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var url = ""
  @State private var username = ""
  @State private var password = ""
  @State private var folder = "PasswordVault"
  @State private var filePassword = ""
  @State private var files: [RemoteBackup] = []
  @State private var target: RemoteBackup?
  @State private var savingSettings = false
  @State private var listing = false
  @State private var transferring = false
  @State private var message: String?
  @State private var failed = false
  private var hasURL: Bool { !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var body: some View {
    Form {
      Section {
        TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField(store.t("用户名", "Username"), text: $username).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField(store.t("服务器密码", "Server password"), text: $password)
        TextField(store.t("文件夹", "Folder"), text: $folder).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button(savingSettings ? store.t("保存中…", "Saving…") : store.t("保存设置", "Save settings")) {
          savingSettings = true
          Task {
            defer { savingSettings = false }
            await store.saveSettings([
              "webdav": .object([
                "url": .string(url), "username": .string(username), "password": .string(password),
                "folder": .string(folder),
              ])
            ])
          }
        }.disabled(savingSettings || transferring || !hasURL)
        Button(listing ? store.t("读取列表中…", "Refreshing…") : store.t("连接并刷新", "Connect & refresh")) {
          run(isList: true) { client in
            files = try await client.list()
            return "\(files.count) \(store.t("份备份", "backups"))"
          }
        }.disabled(listing || transferring || !hasURL)
      } header: {
        Text(store.t("连接设置", "Connection"))
      } footer: {
        Text(
          hasURL
            ? store.t("设置保存在加密资料库中，远程连接需要 HTTPS。", "Settings are kept in the encrypted vault. Remote connections require HTTPS.")
            : store.t("门控原因：请先填写 HTTPS 地址后启用保存与连接。", "Required: enter an HTTPS URL to enable saving and connecting."))
      }
      Section {
        SecureField(store.t("新备份的文件密码", "Password for new backup"), text: $filePassword)
        Button(transferring ? store.t("传输中…", "Transferring…") : store.t("创建并上传加密备份", "Create & upload encrypted backup")) {
          run(isList: false) { client in
            let result = try await store.perform(CoreRequest.export(password: filePassword))
            try await client.upload(Data((result.object["content"]?.string ?? "").utf8))
            files = try await client.list()
            filePassword = ""
            return store.t("已上传加密备份", "Encrypted backup uploaded")
          }
        }.disabled(transferring || !hasURL || filePassword.count < 10)
      } header: {
        Text(store.t("创建备份", "Create backup"))
      } footer: {
        if filePassword.count < 10 {
          Text(store.t("门控原因：独立备份文件密码至少 10 位后启用上传。", "Required: enter a backup password of at least 10 characters."))
        }
      }
      if listing || transferring { ProgressView(listing ? store.t("正在读取备份列表…", "Loading backups…") : store.t("正在传输加密备份…", "Transferring backup…")) }
      if let message { Text(message).foregroundStyle(failed ? .red : .secondary) }
      Section(store.t("备份文件", "Backup files")) {
        ForEach(files) { file in
          Button {
            target = file
            filePassword = ""
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              Text(file.name).foregroundStyle(.primary).lineLimit(2)
              Text(
                "\(file.mobileTimeLabel(chinese: store.chinese)) · \(file.sizeLabel ?? store.t("大小未知", "Unknown size"))"
              ).font(.caption).foregroundStyle(.secondary)
              Text(store.t("合并恢复…", "Merge & restore…")).font(.caption)
            }.padding(.vertical, 5)
          }.disabled(transferring)
        }
      }
    }.navigationTitle("WebDAV")
      .task {
        let config = store.settings["webdav"]?.object ?? [:]
        url = config["url"]?.string ?? ""
        username = config["username"]?.string ?? ""
        password = config["password"]?.string ?? ""
        folder = config["folder"]?.string ?? "PasswordVault"
      }
      .alert(
        store.t("合并恢复备份", "Merge backup"),
        isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })
      ) {
        SecureField(store.t("这份文件的密码", "This file’s password"), text: $filePassword)
        Button(store.t("合并", "Merge")) {
          guard let file = target else { return }
          let secret = filePassword
          target = nil
          run(isList: false) { client in
            let data = try await client.download(file)
            guard let content = String(data: data, encoding: .utf8) else {
              throw VaultError.InvalidData
            }
            let result = try await store.perform(CoreRequest.`import`(content: content, password: secret, kind: "json"))
            try await store.refresh()
            filePassword = ""
            return "\(store.t("已合并", "Merged")): \(Int(result.object["imported"]?.number ?? 0))"
          }
        }
        Button(store.t("取消", "Cancel"), role: .cancel) {
          target = nil
          filePassword = ""
        }
      } message: {
        Text(
          (target?.name ?? "") + "\n"
            + store.t(
              "旧版加密 JSON 使用创建备份时的主密码。其他条目会保留。",
              "For legacy encrypted JSON, use the master password from when the backup was created. Other entries are retained."
            ))
      }
  }
  private func run(isList: Bool, _ action: @escaping (WebDAVClient) async throws -> String) {
    guard !(isList && listing), !transferring else { return }
    if isList { listing = true } else { transferring = true }
    message = nil
    failed = false
    Task {
      defer { if isList { listing = false } else { transferring = false } }
      do {
        let client = try WebDAVClient(
          url: url, username: username, password: password, folder: folder)
        defer { client.close() }
        message = try await action(client)
      } catch {
        failed = true
        message = store.t(
          "操作未完成。请检查连接、服务器权限和文件密码后重试，原资料保留。",
          "Could not complete. Check the connection, server permissions and file password, then retry. Existing data is preserved."
        )
      }
    }
  }
}
