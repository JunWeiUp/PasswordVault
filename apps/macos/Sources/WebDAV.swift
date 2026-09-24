import Foundation
import SwiftUI

final class WebDAVClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let base: URL
  private let authorization: String
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 90
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  init(url: String, username: String, password: String, folder: String) throws {
    guard let root = URL(string: url), root.host != nil, root.user == nil, root.password == nil,
      root.scheme == "https"
        || (root.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(root.host ?? "")),
      !folder.contains(".."), !folder.hasPrefix("/")
    else { throw VaultError.InvalidData }
    base = root.appendingPathComponent(folder, isDirectory: true)
    authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, sameOrigin(url), withinFolder(url) else {
      completionHandler(nil)
      return
    }
    var redirected = request
    redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
    completionHandler(redirected)
  }

  private func sameOrigin(_ url: URL) -> Bool {
    url.scheme == base.scheme && url.host == base.host && url.port == base.port
  }
  private func withinFolder(_ url: URL) -> Bool {
    let root = base.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path == root || path.hasPrefix(root + "/")
  }
  private func request(_ method: String, url: URL, body: Data? = nil) async throws -> Data {
    guard sameOrigin(url), withinFolder(url) else { throw VaultError.InvalidData }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    if method == "PROPFIND" {
      request.setValue("1", forHTTPHeaderField: "Depth")
      request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    }
    if method == "PUT" {
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    }
    let (stream, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw WebDAVFailure.server }
    if !(200..<300).contains(response.statusCode)
      && !(method == "MKCOL" && response.statusCode == 405)
    {
      switch response.statusCode {
      case 401: throw WebDAVFailure.authentication
      case 403: throw WebDAVFailure.permission
      case 404: throw WebDAVFailure.notFound
      default: throw WebDAVFailure.server
      }
    }
    var data = Data()
    for try await byte in stream {
      guard data.count < 64 * 1024 * 1024 else { throw VaultError.InvalidData }
      data.append(byte)
    }
    return data
  }
  func list() async throws -> [RemoteBackup] {
    let data = try await request("PROPFIND", url: base, body: WebDAVListing.requestBody)
    do { return try WebDAVListing.parse(data, base: base) } catch {
      throw WebDAVFailure.invalidListing
    }
  }
  func upload(_ data: Data) async throws {
    _ = try await request("MKCOL", url: base)
    let name = "PasswordVault-\(Int(Date().timeIntervalSince1970)).pvbackup"
    _ = try await request("PUT", url: base.appendingPathComponent(name), body: data)
  }
  func download(_ backup: RemoteBackup) async throws -> Data {
    try await request("GET", url: backup.url)
  }
}

struct WebDAVView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var url = ""
  @State private var username = ""
  @State private var password = ""
  @State private var folder = "PasswordVault"
  @State private var backupPassword = ""
  @State private var files: [RemoteBackup] = []
  @State private var busy = false
  @State private var loaded = false
  @State private var connectionExpanded = true
  @State private var query = ""
  @State private var progress = ""
  @State private var inlineError: String?
  @State private var success: String?
  @State private var pendingRestore: RemoteBackup?
  @State private var failedRestore: RemoteBackup?
  @State private var requestTask: Task<Void, Never>?

  private enum Operation {
    case connect, upload
    case restore(RemoteBackup, String)
  }
  private var filteredFiles: [RemoteBackup] {
    files.filter {
      query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        || $0.timeLabel(chinese: store.chinese).localizedCaseInsensitiveContains(query)
    }
  }
  private var connectionFields: [String] { [url, username, password, folder] }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("WebDAV", systemImage: "externaldrive.badge.icloud").font(.title2.weight(.semibold))
        Spacer()
        Button(store.t("完成", "Done")) {
          requestTask?.cancel()
          dismiss()
        }.keyboardShortcut(.cancelAction)
      }.padding(24)
      Divider()
      if busy || success != nil || inlineError != nil {
        VStack(alignment: .leading, spacing: 10) {
          if busy {
            HStack {
              ProgressView().controlSize(.small)
              Text(progress).font(.callout)
              Spacer()
              Button(store.t("取消", "Cancel")) { requestTask?.cancel() }
            }
          }
          if let success {
            Label(success, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(
              .green
            )
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("webdav.success")
          }
          if let inlineError {
            VStack(alignment: .leading, spacing: 8) {
              Label(inlineError, systemImage: "exclamationmark.circle").font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
                  "webdav.error")
              Button(
                failedRestore == nil
                  ? store.t("重新连接并刷新", "Reconnect and refresh") : store.t("重试恢复…", "Retry restore…")
              ) {
                if let file = failedRestore { pendingRestore = file } else { begin(.connect) }
              }.disabled(busy)
            }
          }
        }.padding(.horizontal, 24).padding(.vertical, 14)
        Divider()
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Label(
              loaded ? store.t("已连接", "Connected") : store.t("备份服务器", "Backup server"),
              systemImage: loaded ? "checkmark.circle" : "server.rack"
            ).font(.headline)
            if loaded {
              Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if loaded {
              Button(store.t("刷新列表", "Refresh list")) { begin(.connect) }.disabled(busy)
              Button(
                connectionExpanded
                  ? store.t("收起连接", "Hide connection") : store.t("编辑连接", "Edit connection")
              ) { connectionExpanded.toggle() }.disabled(busy)
            }
          }
          if connectionExpanded {
            VStack(alignment: .leading, spacing: 12) {
              field(store.t("服务器地址", "Server address")) {
                TextField("https://…", text: $url).accessibilityLabel(
                  store.t("服务器地址", "Server address"))
              }
              HStack(alignment: .top, spacing: 16) {
                field(store.t("服务器账号", "Server username")) {
                  TextField(store.t("用户名", "Username"), text: $username).accessibilityLabel(
                    store.t("服务器账号", "Server username"))
                }
                field(store.t("服务器密码", "Server password")) {
                  SecureField(store.t("WebDAV 登录密码", "WebDAV login password"), text: $password)
                    .accessibilityLabel(store.t("服务器密码", "Server password"))
                }
              }
              field(store.t("备份目录", "Backup folder")) {
                TextField("PasswordVault", text: $folder).accessibilityLabel(
                  store.t("备份目录", "Backup folder"))
              }
              HStack {
                Button(store.t("保存设置", "Save settings")) { saveConfiguration() }
                Button(
                  loaded ? store.t("刷新列表", "Refresh list") : store.t("连接并刷新", "Connect and refresh")
                ) { begin(.connect) }
                Spacer()
                if loaded {
                  Label(store.t("已连接", "Connected"), systemImage: "checkmark.circle").font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }.disabled(busy)
          }
          Divider()
          VStack(alignment: .leading, spacing: 12) {
            Text(store.t("备份与恢复", "Backup and restore")).font(.headline)
            field(store.t("备份文件密码", "Backup-file passphrase")) {
              SecureField(
                store.t("用于加密或解密备份文件", "Encrypts or decrypts backup files"), text: $backupPassword
              )
              .accessibilityLabel(store.t("备份文件密码", "Backup-file passphrase"))
            }
            Text(
              store.t(
                "新备份密码至少 10 个字符。恢复时使用原备份密码；未加密文件可留空。",
                "New backup passphrases need at least 10 characters. To restore, use that file’s passphrase; leave empty for plaintext files."
              )
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(store.t("创建加密备份", "Create encrypted backup")) { begin(.upload) }
              .buttonStyle(VaultButtonStyle(.primary)).tint(Palette.blue).disabled(
                busy || backupPassword.count < 10)
          }.disabled(busy)
          Divider()
          HStack {
            Text(store.t("备份文件", "Backup files")).font(.headline)
            if loaded { Text("\(files.count)").foregroundStyle(.secondary) }
            Spacer()
            Text(store.t("最新优先", "Newest first")).font(.caption).foregroundStyle(.secondary)
          }
          if loaded && !files.isEmpty {
            HStack {
              Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
              TextField(store.t("搜索文件名或日期", "Search filename or date"), text: $query)
              if !query.isEmpty {
                Button {
                  query = ""
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }.buttonStyle(VaultButtonStyle(.plain)).accessibilityLabel(
                  store.t("清除搜索", "Clear search"))
              }
            }
          }
          if filteredFiles.isEmpty {
            VStack(spacing: 8) {
              Image(systemName: "externaldrive").font(.title2).foregroundStyle(.secondary)
              Text(
                !loaded
                  ? store.t("连接后查看备份", "Connect to view backups")
                  : (query.isEmpty
                    ? store.t("此目录还没有备份", "No backups in this folder")
                    : store.t("没有匹配的备份", "No matching backups")))
              Text(
                !loaded
                  ? store.t(
                    "输入服务器信息，然后点击「连接并刷新」。",
                    "Enter the server details, then choose Connect and refresh.")
                  : (query.isEmpty
                    ? store.t("可以创建第一份加密备份。", "Create your first encrypted backup.")
                    : store.t("换一个关键词或清除搜索。", "Try another keyword or clear the search."))
              ).font(.caption).foregroundStyle(.secondary)
              if !query.isEmpty { Button(store.t("清除搜索", "Clear search")) { query = "" } }
            }.frame(maxWidth: .infinity).padding(.vertical, 20)
          } else {
            LazyVStack(spacing: 0) {
              ForEach(filteredFiles) { file in
                HStack(spacing: 18) {
                  VStack(alignment: .leading, spacing: 7) {
                    Text(file.name).lineLimit(1).truncationMode(.middle).help(file.name)
                    HStack(spacing: 14) {
                      Label(file.timeLabel(chinese: store.chinese), systemImage: "clock").help(
                        file.timeExplanation(chinese: store.chinese))
                      Label(
                        file.sizeLabel ?? store.t("大小未知", "Size unavailable"), systemImage: "doc")
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                  }.frame(maxWidth: .infinity, alignment: .leading)
                  Button(store.t("恢复…", "Restore…")) { pendingRestore = file }
                    .accessibilityLabel(store.t("恢复备份 \(file.name)", "Restore backup \(file.name)"))
                    .disabled(busy)
                }.padding(.vertical, 13)
                Divider()
              }
            }
          }
          Text(
            store.t(
              "连接信息会加密保存。列表时间按本机时区显示；文件内容仅在恢复时下载。",
              "Connection settings are saved encrypted. Times use your local time zone; backup contents are downloaded only for restore."
            )
          )
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24)
      }
    }.textFieldStyle(.roundedBorder).frame(width: 660, height: 620)
      .onAppear {
        let config = store.settings["webdav"]?.object ?? [:]
        url = config["url"]?.string ?? ""
        username = config["username"]?.string ?? ""
        password = config["password"]?.string ?? ""
        folder = config["folder"]?.string ?? "PasswordVault"
      }
      .onChange(of: connectionFields) { _ in
        files = []
        loaded = false
        success = nil
        inlineError = nil
        failedRestore = nil
      }
      .onDisappear {
        requestTask?.cancel()
        password = ""
        backupPassword = ""
      }
      .sheet(item: $pendingRestore) { file in
        WebDAVRestoreSheet(
          file: file, initialPassword: file.isLegacyEncrypted ? "" : backupPassword
        ) { passphrase in
          begin(.restore(file, passphrase))
        }
      }
  }

  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      content()
    }
  }
  private func configured() throws -> WebDAVClient {
    do {
      return try WebDAVClient(url: url, username: username, password: password, folder: folder)
    } catch { throw WebDAVFailure.invalidConfiguration }
  }
  private func saveConfiguration() {
    guard !busy else { return }
    do { _ = try configured() } catch {
      inlineError = store.errorMessage(error)
      return
    }
    busy = true
    inlineError = nil
    success = nil
    progress = store.t("正在保存设置…", "Saving settings…")
    requestTask = Task {
      defer { busy = false }
      do {
        var settings = store.settings
        settings["webdav"] = .object([
          "url": .string(url), "username": .string(username), "password": .string(password),
          "folder": .string(folder),
        ])
        _ = try await store.perform(["op": .string("settings"), "settings": .object(settings)])
        store.settings = settings
        success = store.t("连接设置已加密保存。", "Connection settings saved encrypted.")
      } catch { inlineError = store.errorMessage(error) }
    }
  }
  private func begin(_ operation: Operation) {
    guard !busy else { return }
    busy = true
    inlineError = nil
    failedRestore = nil
    success = nil
    switch operation {
    case .connect: progress = store.t("正在连接并读取备份列表…", "Connecting and reading backups…")
    case .upload:
      progress = store.t(
        "正在保存最新编辑并创建加密备份…", "Saving recent edits and creating an encrypted backup…")
    case .restore: progress = store.t("正在下载并合并备份…", "Downloading and merging backup…")
    }
    requestTask = Task {
      defer { busy = false }
      do {
        let client = try configured()
        switch operation {
        case .connect:
          files = try await client.list()
          loaded = true
          connectionExpanded = false
          success = store.t("列表已更新，共 \(files.count) 份备份。", "List updated: \(files.count) backups.")
        case .upload:
          let value = try await store.perform([
            "op": .string("export"), "password": .string(backupPassword),
          ])
          try Task.checkCancellation()
          try await client.upload(Data((value.object["content"]?.string ?? "").utf8))
          success = store.t("加密备份已上传。", "Encrypted backup uploaded.")
          do {
            files = try await client.list()
            loaded = true
          } catch {
            inlineError = store.t(
              "备份已上传，但列表刷新失败。请刷新列表，无需重复上传。",
              "The backup was uploaded, but refreshing failed. Refresh the list instead of uploading again."
            )
          }
        case .restore(let file, let passphrase):
          let data = try await client.download(file)
          try Task.checkCancellation()
          let value = try await store.perform([
            "op": .string("import"), "content": .string(String(decoding: data, as: UTF8.self)),
            "password": .string(passphrase),
          ])
          await store.refresh()
          let count = Int(value.object["imported"]?.number ?? 0)
          success =
            count == 0
            ? store.t("合并完成：没有需要新增或更新的记录。", "Merge complete: no records needed adding or updating.")
            : store.t(
              "合并完成：新增或更新了 \(count) 条记录。", "Merge complete: added or updated \(count) records.")
        }
      } catch is CancellationError {
        inlineError = store.t(
          "操作已取消。上传中断时，请先刷新列表确认结果。",
          "Operation cancelled. If an upload was interrupted, refresh the list to check its result."
        )
      } catch {
        if case .restore(let file, _) = operation {
          failedRestore = file
          if file.isLegacyEncrypted, let vaultError = error as? VaultError,
            case .Authentication = vaultError
          {
            inlineError = store.t(
              "旧备份无法解密。请使用创建这份备份时的旧版主密码（不是 WebDAV 登录密码或新版备份密码）；文件损坏也可能导致此错误。",
              "Cannot decrypt this legacy backup. Use the old app’s master password from when it was created, not the WebDAV login or a new backup passphrase. A damaged file can also cause this error."
            )
            return
          }
        }
        inlineError = store.errorMessage(error, context: .backup)
      }
    }
  }
}

private struct WebDAVRestoreSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let file: RemoteBackup
  let onRestore: (String) -> Void
  @State private var passphrase: String
  @FocusState private var passwordFocused: Bool

  init(file: RemoteBackup, initialPassword: String, onRestore: @escaping (String) -> Void) {
    self.file = file
    self.onRestore = onRestore
    _passphrase = State(initialValue: initialPassword)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(
        file.isLegacyEncrypted
          ? store.t("恢复旧版备份", "Restore legacy backup") : store.t("恢复备份", "Restore backup")
      )
      .font(.title2.weight(.semibold))
      VStack(alignment: .leading, spacing: 6) {
        Text(file.name).font(.callout).lineLimit(2).textSelection(.enabled)
        Text(
          "\(file.timeLabel(chinese: store.chinese)) · \(file.sizeLabel ?? store.t("大小未知", "Size unavailable"))"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Text(
          file.isLegacyEncrypted
            ? store.t("备份时的旧版主密码", "Original legacy master password")
            : store.t("这份备份的密码", "This backup’s passphrase")
        )
        .font(.headline)
        SecureField(store.t("输入此备份使用的密码", "Enter this file’s password"), text: $passphrase)
          .textFieldStyle(.roundedBorder).focused($passwordFocused).onSubmit(restore)
        Text(
          file.isLegacyEncrypted
            ? store.t(
              "旧版 WebDAV 备份使用当时的主密码加密。即使后来改过主密码，这份文件仍需原密码；旧密码不足 10 位也可恢复。",
              "Legacy WebDAV backups use the master password in effect when they were created. Later password changes do not change this file. Legacy passwords may be shorter than 10 characters."
            )
            : store.t(
              "使用创建此备份时设置的密码。旧版加密 JSON 使用当时的主密码；未加密文件可留空。",
              "Use the passphrase set when this backup was created. Legacy encrypted JSON uses the old master password; leave empty for an unencrypted file."
            )
        )
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Text(
        store.t(
          "恢复会合并到当前资料库：同一记录保留较新的一方，回收站状态也会合并，当前独有的记录会保留。",
          "Restore merges into this vault: keep the newer version of matching records, including Trash status; records unique to this vault remain."
        )
      )
      .font(.callout).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(store.t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(store.t("恢复并合并", "Restore and merge"), action: restore)
          .buttonStyle(VaultButtonStyle(.primary)).tint(Palette.blue).keyboardShortcut(
            .defaultAction
          )
          .disabled(file.isLegacyEncrypted && passphrase.isEmpty)
      }
    }.padding(28).frame(width: 470)
      .onAppear { passwordFocused = true }
      .onDisappear { passphrase = "" }
  }

  private func restore() {
    guard !file.isLegacyEncrypted || !passphrase.isEmpty else { return }
    let password = passphrase
    dismiss()
    onRestore(password)
  }
}
