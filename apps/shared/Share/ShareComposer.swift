import SwiftUI

struct ShareComposer: View {
  let id: String
  let settings: [String: JSONValue]
  let unlocked: Bool
  let t: (String, String) -> String
  let perform: ([String: JSONValue]) async throws -> JSONValue
  let refresh: () async -> Void
  let copy: (String) -> Void
  @State private var endpoint = ""
  @State private var token = ""
  @State private var managed: [JSONValue] = []
  @State private var revokeID: String?
  @State private var fields: [String] = []
  @State private var selected = Set(["title", "username", "password", "url", "note"])
  @State private var attachments: [JSONValue] = []
  @State private var chosenFiles = Set<String>()
  @State private var expiry = 604800
  @State private var email = ""
  @State private var restrictEmail = false
  @State private var emailSupported = false
  @State private var link = ""
  @State private var shareID = ""
  @State private var createdClient: ShareServiceClient?
  @State private var busy = false
  @State private var message: String?
  @State private var task: Task<Void, Never>?
  var body: some View {
    Form {
      Section {
        Text(
          t(
            "分享所选字段的加密副本。接收人无需安装应用；更改原条目不会更新此链接。撤销无法收回已下载的副本。",
            "Share an encrypted copy of selected fields. Recipients need no app. Later edits do not update this link; revocation cannot retract downloaded copies."
          ))
      }
      Section(t("分享服务", "Share service")) {
        TextField(t("服务地址（HTTPS）", "Service URL (HTTPS)"), text: $endpoint)
        SecureField(t("服务访问令牌", "Service access token"), text: $token)
        Button(t("检查并保存配置", "Check and save configuration")) {
          run {
            let client = try ShareServiceClient(endpoint: endpoint, token: token)
            let capabilities = try await client.capabilities()
            _ = try await client.list()
            _ = try await perform([
              "op": .string("settings"),
              "settings": .object([
                "shareServiceURL": .string(endpoint), "shareServiceToken": .string(token),
              ]),
            ])
            await refresh()
            emailSupported = capabilities.object["emailVerification"]?.bool ?? false
            message =
              emailSupported
              ? t("配置已保存，可验证接收邮箱。", "Saved. Recipient email verification is available.")
              : t("配置已保存；服务尚未配置邮件发送。", "Saved. SMTP is not configured on the service.")
          }
        }
      }
      Section(t("包含哪些内容", "Include these fields")) {
        ForEach(fields, id: \.self) { field in
          Toggle(
            fieldName(field),
            isOn: Binding(
              get: { selected.contains(field) },
              set: { if $0 { selected.insert(field) } else { selected.remove(field) } }))
        }
        ForEach(attachments, id: \.self) { file in
          let fileID = file.object["id"]?.string ?? ""
          Toggle(
            file.object["name"]?.string ?? t("附件", "Attachment"),
            isOn: Binding(
              get: { chosenFiles.contains(fileID) },
              set: { if $0 { chosenFiles.insert(fileID) } else { chosenFiles.remove(fileID) } }))
        }
        Text(
          t(
            "密码历史与 Passkey 私钥不会包含。笔记字段是文字摘要；附件需要单独勾选。",
            "Password history and Passkey private keys are excluded. Note fields contain a text summary; select attachments separately."
          )
        ).font(.caption)
      }
      Section(t("访问规则", "Access")) {
        Picker(t("有效期", "Expires in"), selection: $expiry) {
          Text(t("一小时", "One hour")).tag(3600)
          Text(t("一天", "One day")).tag(86400)
          Text(t("七天", "Seven days")).tag(604800)
          Text(t("三十天", "Thirty days")).tag(2_592_000)
        }
        Toggle(t("仅指定邮箱可查看", "Restrict to a recipient email"), isOn: $restrictEmail).disabled(
          !emailSupported)
        if restrictEmail { TextField(t("接收邮箱", "Recipient email"), text: $email) }
        Button(t("创建加密分享链接", "Create encrypted share link")) {
          run {
            let client = try ShareServiceClient(endpoint: endpoint, token: token)
            let envelope = try await perform([
              "op": .string("share-seal"), "id": .string(id),
              "fields": .array(fields.filter { selected.contains($0) }.map(JSONValue.string)),
              "attachmentIds": .array(chosenFiles.sorted().map(JSONValue.string)),
            ])
            let result = try await client.create(
              envelope, expiresIn: expiry, email: restrictEmail ? email : nil)
            try Task.checkCancellation()
            link = result
            shareID = envelope.object["id"]?.string ?? ""
            createdClient = client
          }
        }.disabled(
          fields.filter { selected.contains($0) }.isEmpty || (restrictEmail && email.isEmpty))
      }
      if !link.isEmpty {
        Section(t("完整链接含有解密密钥", "The full link includes the decryption key")) {
          Text(link).font(.caption.monospaced()).textSelection(.enabled)
          Button(t("复制链接", "Copy link")) { copy(link) }
          Button(t("撤销此链接", "Revoke this link"), role: .destructive) {
            run {
              try await createdClient?.revoke(shareID)
              link = ""
              shareID = ""
              createdClient = nil
              message = t("链接已撤销。", "Link revoked.")
            }
          }
          Text(
            t(
              "服务端不保存解密密钥，关闭后无法重新取回完整链接。",
              "The service does not store the key. You cannot retrieve the complete link after closing this screen."
            )
          ).font(.caption)
        }
      }
      Section(t("管理未到期的链接", "Manage active links")) {
        Button(t("刷新分享列表", "Refresh share list")) {
          run { managed = try await ShareServiceClient(endpoint: endpoint, token: token).list().object["shares"]?.array ?? [] }
        }
        ForEach(managed, id: \.self) { share in
          let sid = share.object["id"]?.string ?? ""
          VStack(alignment: .leading) {
            Text(sid).font(.caption.monospaced())
            if case .number(let expiry) = share.object["expiry"] {
              Text(Date(timeIntervalSince1970: expiry / 1000), style: .date)
            }
            Button(t("撤销链接", "Revoke link"), role: .destructive) { revokeID = sid }
          }
        }
      }
      if let message { Section { Text(message) } }
      if busy { ProgressView() }
    }.disabled(busy || !unlocked)
      .task {
        endpoint = settings["shareServiceURL"]?.string ?? ""
        token = settings["shareServiceToken"]?.string ?? ""
        do {
          let options = try await perform(["op": .string("share-options"), "id": .string(id)])
          fields = options.object["fields"]?.array.map(\.string) ?? []
          attachments = options.object["attachments"]?.array ?? []
        } catch { message = t("无法读取条目。", "Could not read this entry.") }
      }
      .onChange(of: unlocked) { if !$0 { clear() } }
      .onDisappear { clear() }
      .confirmationDialog(t("撤销链接？已下载的副本无法收回。", "Revoke link? Downloaded copies cannot be retracted."), isPresented: Binding(get: { revokeID != nil }, set: { if !$0 { revokeID = nil } })) {
        Button(t("撤销", "Revoke"), role: .destructive) {
          guard let sid = revokeID else { return }
          revokeID = nil
          run {
            let client = try ShareServiceClient(endpoint: endpoint, token: token)
            try await client.revoke(sid)
            managed = try await client.list().object["shares"]?.array ?? []
            if shareID == sid { link = ""; createdClient = nil }
          }
        }
      }
  }
  private func fieldName(_ key: String) -> String {
    let labels = [
      "title": "标题", "username": "用户名", "password": "密码", "url": "网址", "note": "备注 / 笔记摘要",
      "secret": "验证码密钥", "mnemonic": "助记词", "privateKey": "私钥", "address": "地址", "network": "网络",
      "category": "分类", "tags": "标签", "card": "银行卡资料（含安全码）", "identity": "身份资料", "customFields": "全部自定义字段（含隐藏值）",
    ]
    let english = [
      "title": "Title", "username": "Username", "password": "Password", "url": "Website",
      "note": "Notes / text summary", "secret": "Authenticator secret",
      "mnemonic": "Recovery phrase", "privateKey": "Private key", "address": "Address",
      "network": "Network", "category": "Category", "tags": "Tags", "card": "Card details (including security code)", "identity": "Identity details", "customFields": "All custom fields (including concealed values)",
    ]
    return t(labels[key] ?? key, english[key] ?? key)
  }
  private func clear() {
    task?.cancel()
    task = nil
    token = ""
    link = ""
    createdClient = nil
    managed = []
    revokeID = nil
    fields = []
    attachments = []
    chosenFiles = []
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy, unlocked else { return }
    busy = true
    message = nil
    task = Task { @MainActor in
      defer { busy = false }
      do { try await action() } catch {
        if !Task.isCancelled {
          message = t(
            "分享操作未完成。请检查服务配置、权限、网络及附件大小。",
            "Share operation incomplete. Check service configuration, authorization, network and attachment size."
          )
        }
      }
    }
  }
}
