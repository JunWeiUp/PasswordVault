import SwiftUI

struct MobileEntryDetail: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let id: String
  @State private var editor: VaultItem?
  @State private var revealing = Set<String>()
  @State private var deleting = false
  @State private var code = ""
  @State private var nextCode = ""
  @State private var nextIn = 0
  /// Field key waiting for the user's confirmation before a wallet secret is shown.
  @State private var confirmingReveal: String?
  @State private var screenCaptured = UIScreen.main.isCaptured
  @Environment(\.openURL) private var openURL
  private var item: VaultItem? { store.items.first { $0.id == id } }
  private func totpSource(for item: VaultItem) -> (secret: String, period: Double)? {
    guard !item.isDeleted else { return nil }
    let embedded = item.string("secret").trimmingCharacters(in: .whitespacesAndNewlines)
    if !embedded.isEmpty { return (embedded, max(item.number("period", fallback: 30), 1)) }
    guard item.type == "password" else { return nil }
    let linkedID = item.string("linkedTotpId")
    guard !linkedID.isEmpty,
      let linked = store.items.first(where: { $0.id == linkedID && $0.type == "totp" && !$0.isDeleted })
    else { return nil }
    let secret = linked.string("secret").trimmingCharacters(in: .whitespacesAndNewlines)
    return secret.isEmpty ? nil : (secret, max(linked.number("period", fallback: 30), 1))
  }
  private func siteURL(for raw: String) -> URL? {
    let first = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespacesAndNewlines).first ?? ""
    guard !first.isEmpty else { return nil }
    let normalized = first.contains("://") ? first : "https://\(first)"
    guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else { return nil }
    return url
  }
  private func passwordStrength(_ pw: String) -> Int {
    guard !pw.isEmpty else { return 0 }
    let classes = [
      pw.range(of: "[a-z]", options: .regularExpression) != nil,
      pw.range(of: "[A-Z]", options: .regularExpression) != nil,
      pw.range(of: "[0-9]", options: .regularExpression) != nil,
      pw.range(of: "[^a-zA-Z0-9]", options: .regularExpression) != nil,
    ].filter { $0 }.count
    if pw.count < 10 { return 1 }
    if pw.count < 12 || classes < 2 { return 2 }
    if pw.count < 16 || classes < 3 { return 3 }
    return 4
  }
  var body: some View {
    Group {
      if let item {
        List {
          Section {
            VStack(alignment: .leading, spacing: 6) {
              Text(item.title).font(.title2.bold())
              if !item.category.isEmpty {
                Label(item.category, systemImage: "folder").font(.subheadline).foregroundStyle(.secondary)
              }
            }.padding(.vertical, 2)
            if item.type == "password" && !item.isDeleted {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  Button { store.copy(item.password) } label: {
                    Label(store.t("复制密码", "Copy password"), systemImage: "doc.on.doc")
                  }
                  .buttonStyle(.borderedProminent)
                  .disabled(item.password.isEmpty)
                  if !item.username.isEmpty {
                    Button { store.copy(item.username) } label: {
                      Text(store.t("复制用户名", "Copy username"))
                    }.buttonStyle(.bordered)
                  }
                  if totpSource(for: item) != nil {
                    Button { store.copy(code) } label: {
                      Label(code.isEmpty ? store.t("复制验证码", "Copy code") : MobileCodeRow.grouped(code), systemImage: "timer")
                    }
                    .buttonStyle(.bordered)
                    .disabled(code.isEmpty)
                  }
                  if let url = siteURL(for: item.string("url")) {
                    Button { openURL(url) } label: {
                      Label(store.t("打开网站", "Open site"), systemImage: "safari")
                    }.buttonStyle(.bordered)
                  }
                }
                .controlSize(.small)
              }
            }
          }
          if item.type == "password" {
            Section(store.t("账号信息", "Credentials")) {
              value(store.t("用户名", "Username"), item.username, key: "username")
              value(store.t("密码", "Password"), item.password, key: "password", secret: true)
              if !item.password.isEmpty {
                let score = passwordStrength(item.password)
                let color: Color = score <= 1 ? .red : score == 2 ? .orange : .green
                let text = [store.t("很弱", "Very weak"), store.t("弱", "Weak"), store.t("一般", "Fair"), store.t("良好", "Good"), store.t("强", "Strong")][min(max(score, 0), 4)]
                HStack(spacing: 6) {
                  ForEach(1...4, id: \.self) { index in
                    Capsule()
                      .fill(index <= score ? color : Color.secondary.opacity(0.2))
                      .frame(height: 4)
                  }
                  Text(text).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 2)
              }
              if let source = totpSource(for: item) {
                HStack(spacing: 12) {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(store.t("二次验证码", "2FA code")).font(.caption).foregroundStyle(.secondary)
                    Text(MobileCodeRow.grouped(code))
                      .font(.title3.weight(.semibold).monospaced())
                      .foregroundStyle(!code.isEmpty && nextIn <= 5 ? Color.orange : Color.accentColor)
                  }
                  Spacer()
                  ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(nextIn) / CGFloat(source.period))
                      .stroke(nextIn <= 5 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                      .rotationEffect(.degrees(-90))
                    Text("\(nextIn)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                  }.frame(width: 28, height: 28)
                  Button { store.copy(code) } label: {
                    Image(systemName: "doc.on.doc")
                  }
                  .buttonStyle(.bordered).controlSize(.small)
                  .disabled(code.isEmpty)
                  .accessibilityLabel(store.t("复制验证码", "Copy code"))
                }.padding(.vertical, 2)
              }
              value(store.t("网站", "Website"), item.string("url"), key: "url")
            }
            ForEach(Array((item.fields["accounts"]?.array ?? []).enumerated()), id: \.offset) {
              index, account in
              Section(store.t("更多账号", "Additional account")) {
                value(
                  store.t("用户名", "Username"), account.object["username"]?.string ?? "",
                  key: "user\(index)")
                value(
                  store.t("密码", "Password"), account.object["password"]?.string ?? "",
                  key: "pass\(index)", secret: true)
              }
            }
          } else if item.type == "totp" {
            Section(store.t("验证码", "Verification code")) {
              let period = max(item.number("period", fallback: 30), 1)
              HStack(spacing: 14) {
                ZStack {
                  Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3.5)
                  Circle().trim(from: 0, to: code.isEmpty ? 0 : CGFloat(nextIn) / CGFloat(period))
                    .stroke(!code.isEmpty && nextIn <= 5 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                  Text("\(nextIn)").font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(!code.isEmpty && nextIn <= 5 ? Color.orange : Color.secondary)
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                  Text(MobileCodeRow.grouped(code)).font(
                    .system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundStyle(!code.isEmpty && nextIn <= 5 ? Color.orange : Color.primary)
                    .accessibilityIdentifier("code.current")
                  if !nextCode.isEmpty {
                    Text(store.t("下一个 \(MobileCodeRow.grouped(nextCode)) · \(nextIn) 秒后生效", "Next \(MobileCodeRow.grouped(nextCode)) · in \(nextIn) s"))
                      .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                      .accessibilityIdentifier("code.next")
                  }
                }
              }.padding(.vertical, 4)
              Button(store.t("复制验证码", "Copy code")) { store.copy(code) }.disabled(code.isEmpty)
              value(
                store.t("设置密钥", "Setup key"), item.string("secret"), key: "secret", secret: true)
              LabeledContent(store.t("算法 · 位数 · 周期", "Algorithm · digits · period"),
                value: store.t("SHA1 · 6 位 · \(Int(max(item.number("period", fallback: 30), 1))) 秒", "SHA1 · 6 · \(Int(max(item.number("period", fallback: 30), 1))) s"))
            }
            // Accounts that store the same setup key, as on the desktop. Linking needs no
            // extra field; there is no separate link record in the vault format.
            Section {
              let linked = CodeSetup.linkedAccounts(item, in: store.items)
              if linked.isEmpty {
                Text(store.t("未找到使用相同密钥的账号。", "No account uses the same setup key."))
                  .foregroundStyle(.secondary).accessibilityIdentifier("code.linked.none")
              }
              ForEach(linked) { account in
                NavigationLink { MobileEntryDetail(id: account.id) } label: {
                  VStack(alignment: .leading) {
                    Text(account.title.isEmpty ? store.t("未命名", "Untitled") : account.title)
                    if !account.username.isEmpty { Text(account.username).font(.caption).foregroundStyle(.secondary) }
                  }
                }
              }
            } header: {
              Text(store.t("关联账号", "Linked accounts"))
            }
          } else if item.type == "crypto" {
            Section(store.t("钱包", "Wallet")) {
              value(store.t("网络", "Network"), item.string("network"), key: "network")
              value(store.t("地址", "Address"), item.string("address"), key: "address")
              value(
                store.t("私钥", "Private key"), item.string("privateKey"), key: "privateKey",
                secret: true, confirm: true)
              // Recovery phrases are never copied to the clipboard; they are shown only after confirmation.
              value(
                store.t("助记词", "Recovery phrase"), item.string("mnemonic"), key: "mnemonic",
                secret: true, confirm: true, copyable: false)
            }
          }
          PasskeyRecordsView(item: item, perform: store.perform, refresh: { try? await store.refresh() }, t: store.t, editable: store.canEdit(item))
          let customFields = item.fields["customFields"]?.array ?? []
          if item.type == "identity" {
            let documents = IdentityDocument.fields.filter { !IdentityDocument.value(customFields, $0.id).isEmpty }
            let name = [item.fields["identity"]?.object["lastName"]?.string ?? "", item.fields["identity"]?.object["firstName"]?.string ?? ""]
              .filter { !$0.isEmpty }.joined(separator: store.chinese ? "" : " ")
            if !documents.isEmpty || !name.isEmpty {
              Section(store.t("证件信息", "Document")) {
                value(store.t("姓名", "Name"), name, key: "document.name")
                ForEach(documents, id: \.id) { spec in
                  value(store.t(spec.label, spec.english), IdentityDocument.value(customFields, spec.id), key: spec.id,
                    secret: spec.kind == "concealed", copyAfterReveal: spec.kind == "concealed")
                }
              }
            }
          }
          if ["creditCard", "identity"].contains(item.type) {
            let group = item.type == "creditCard" ? "card" : "identity"
            let object = item.fields[group]?.object ?? [:]
            let table = item.type == "creditCard" ? StructuredLabels.card : StructuredLabels.identity
            // Known keys in their usual order, then any other stored keys.
            let keys = table.map(\.0).filter { object[$0] != nil && !(item.type == "identity" && ["firstName", "lastName"].contains($0)) }
              + object.keys.filter { key in !table.contains { $0.0 == key } }.sorted()
            if keys.contains(where: { !(object[$0]?.string ?? "").isEmpty }) {
              Section(item.type == "creditCard" ? store.t("银行卡", "Payment card") : store.t("身份资料", "Identity")) {
                ForEach(keys, id: \.self) { key in
                  value(StructuredLabels.label(key, type: item.type, t: store.t), object[key]?.string ?? "", key: "structured-\(key)", secret: ["number", "securityCode"].contains(key))
                }
              }
            }
          }
          let others = Array(customFields.enumerated()).filter { item.type != "identity" || !IdentityDocument.isDocument($0.element) }
          if !others.isEmpty {
            Section(store.t("自定义字段", "Custom fields")) {
              ForEach(others, id: \.offset) { index, field in
                value(field.object["label"]?.string ?? "", field.object["value"]?.string ?? "", key: "custom-\(index)", secret: field.object["kind"]?.string == "concealed")
              }
            }
          }
          if let history = item.fields["passwordHistory"]?.array, !history.isEmpty {
            Section(store.t("密码历史", "Password history")) {
              ForEach(Array(history.enumerated()), id: \.offset) { index, entry in
                value(
                  entry.object["changedAt"]?.string ?? store.t("历史密码", "Previous password"),
                  entry.object["password"]?.string ?? "", key: "history-\(index)", secret: true)
              }
            }
          }
          if !item.note.isEmpty {
            Section(store.t("备注", "Notes")) {
              if item.string("noteFormat") == "rich-v1" { Text(item.note).textSelection(.enabled) }
              else { MobileMarkdown(source: item.note) }
            }
          }
          if item.string("noteFormat") == "rich-v1" {
            Button(store.t("打开图文笔记", "Open rich note")) { editor = item }
              .foregroundStyle(.secondary)
          }
          if !store.canEdit(item) && item.string("noteFormat") != "rich-v1" {
            Section { Text(store.t("此共享条目为只读。", "This shared entry is read-only.")) }
          }
          Section(store.t("记录", "History")) {
            NavigationLink(store.t("版本历史", "Version history")) { MobileHistoryView(id: id) }
          }
          if store.canEdit(item) {
            Section {
              if item.isDeleted {
                Button(store.t("恢复", "Restore")) {
                  Task { if await store.trash(item) { dismiss() } }
                }
              }
              Button(
                item.isDeleted
                  ? store.t("永久删除…", "Delete permanently…") : store.t("移到回收站…", "Move to Trash…"),
                role: .destructive
              ) { deleting = true }
              .disabled(item.isDeleted && !item.string("sharedVaultId").isEmpty)
              if item.isDeleted && !item.string("sharedVaultId").isEmpty {
                Text(
                  store.t(
                    "共享条目保留在回收站，可选择恢复。", "Shared entries remain in Trash and can be restored.")
                ).foregroundStyle(.secondary)
              }
            }
          }
        }
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
          if !item.isDeleted && store.canEdit(item) {
            Button {
              Task { await store.toggle(id, field: "isFavorite") }
            } label: {
              Image(systemName: item.isFavorite ? "star.fill" : "star")
            }.accessibilityLabel(store.t("收藏", "Favorite"))
            Button(store.t("编辑", "Edit")) { editor = item }
          }
        }
        .confirmationDialog(
          item.isDeleted
            ? store.t("永久删除？", "Delete permanently?") : store.t("移到回收站？", "Move to Trash?"),
          isPresented: $deleting, titleVisibility: .visible
        ) {
          Button(store.t("删除", "Delete"), role: .destructive) {
            Task {
              if item.isDeleted { await store.remove(item) } else { await store.trash(item) }
              if store.error == nil { dismiss() }
            }
          }
        } message: {
          Text(item.title)
        }
      } else {
        Text(store.t("此条目已移除", "Entry removed"))
      }
    }
    .sheet(item: $editor) { item in
      if item.type == "secureNote" { MobileRichNoteEditor(item: item) } else { MobileEntryEditor(item: item) }
    }
    .confirmationDialog(
      store.t("显示钱包密钥？", "Show wallet secret?"),
      isPresented: Binding(get: { confirmingReveal != nil }, set: { if !$0 { confirmingReveal = nil } }),
      titleVisibility: .visible
    ) {
      Button(store.t("确认周围无人，显示", "No one is watching — show")) {
        if let key = confirmingReveal { revealing.insert(key) }
        confirmingReveal = nil
      }
      Button(store.t("取消", "Cancel"), role: .cancel) { confirmingReveal = nil }
    } message: {
      Text(store.t("拿到它的人可以转走全部资产。请确认周围无人，并且没有在录屏或投屏。", "Anyone who sees it can move all funds. Make sure no one is watching and the screen is not being recorded or mirrored."))
    }
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
      screenCaptured = UIScreen.main.isCaptured
    }
    .onDisappear { revealing.removeAll() }
    .task(id: item) {
      guard let item, let source = totpSource(for: item) else { return }
      let period = source.period
      func totp(_ time: Double) async -> String {
        (try? await store.perform(CoreRequest.totp(secret: source.secret, time: time.rounded(.down), period: period))
          .object["code"]?.string) ?? ""
      }
      while !Task.isCancelled {
        let now = Date().timeIntervalSince1970
        let next = MobileCodeRow.nextWindow(now: now, period: period)
        code = await totp(now)
        nextCode = item.type == "totp" && !code.isEmpty ? await totp(next.time) : ""
        nextIn = next.remaining
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
      }
    }
  }
  @ViewBuilder private func value(
    _ label: String, _ value: String, key: String, secret: Bool = false,
    confirm: Bool = false, copyable: Bool = true, copyAfterReveal: Bool = false
  ) -> some View {
    if !value.isEmpty {
      // Confirmed secrets stay hidden while the screen is recorded or mirrored.
      let hiddenByCapture = confirm && screenCaptured
      let shown = !secret || (revealing.contains(key) && !hiddenByCapture)
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if shown && !copyable {
              Text(value).font(.body.monospaced())
            } else {
              Text(shown ? value : "••••••••••••").font(.body.monospaced()).textSelection(.enabled)
            }
          }
          Spacer(minLength: 8)
          HStack(spacing: 6) {
            if secret {
              Button {
                if revealing.contains(key) { revealing.remove(key) }
                else if confirm { confirmingReveal = key }
                else { revealing.insert(key) }
              } label: {
                Image(systemName: revealing.contains(key) ? "eye.slash" : "eye")
                  .frame(width: 28, height: 28)
              }
              .accessibilityLabel(revealing.contains(key) ? store.t("隐藏", "Hide") : store.t("显示", "Show"))
            }
            if copyable {
              Button { store.copy(value) } label: {
                Image(systemName: "doc.on.doc")
                  .frame(width: 28, height: 28)
              }
              .disabled(copyAfterReveal && !revealing.contains(key))
              .accessibilityLabel(store.t("复制", "Copy"))
            }
          }.buttonStyle(.bordered).controlSize(.small)
        }
        if hiddenByCapture && revealing.contains(key) {
          Text(store.t("正在录屏或投屏，已隐藏。", "Hidden while the screen is recorded or mirrored."))
            .font(.caption).foregroundStyle(.orange)
        }
        if !copyable {
          Text(store.t("助记词不支持复制，请抄写在离线介质上。", "Recovery phrases can't be copied; write them down offline."))
            .font(.caption).foregroundStyle(.secondary)
        }
      }.padding(.vertical, 2)
    }
  }
}
