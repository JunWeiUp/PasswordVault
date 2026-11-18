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
  private var item: VaultItem? { store.items.first { $0.id == id } }
  var body: some View {
    Group {
      if let item {
        List {
          Section {
            Text(item.title).font(.title2.bold())
            NavigationLink(store.t("版本历史", "Version history")) { MobileHistoryView(id: id) }
            if !item.category.isEmpty {
              Label(item.category, systemImage: "folder").foregroundStyle(.secondary)
            }
          }
          if item.type == "password" {
            Section(store.t("账号信息", "Credentials")) {
              value(store.t("用户名", "Username"), item.username, key: "username")
              value(store.t("密码", "Password"), item.password, key: "password", secret: true)
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
              Text(MobileCodeRow.grouped(code)).font(
                .system(size: 36, weight: .medium, design: .monospaced))
                .foregroundStyle(!code.isEmpty && nextIn <= 5 ? Color.orange : Color.primary)
                .accessibilityIdentifier("code.current")
              if !nextCode.isEmpty {
                Text(store.t("下一个 \(MobileCodeRow.grouped(nextCode)) · \(nextIn) 秒后生效", "Next \(MobileCodeRow.grouped(nextCode)) · in \(nextIn) s"))
                  .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                  .accessibilityIdentifier("code.next")
              }
              Button(store.t("复制验证码", "Copy code")) { store.copy(code) }.disabled(code.isEmpty)
              value(
                store.t("设置密钥", "Setup key"), item.string("secret"), key: "secret", secret: true)
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
          if ["creditCard", "identity"].contains(item.type) {
            let group = item.type == "creditCard" ? "card" : "identity"
            Section(store.t("结构化资料", "Structured details")) {
              ForEach((item.fields[group]?.object ?? [:]).keys.sorted(), id: \.self) { key in
                value(key, item.fields[group]?.object[key]?.string ?? "", key: "structured-\(key)", secret: ["number", "securityCode"].contains(key))
              }
            }
          }
          if let fields = item.fields["customFields"]?.array, !fields.isEmpty {
            Section(store.t("自定义字段", "Custom fields")) {
              ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
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
      guard let item, item.type == "totp" else { return }
      let period = max(item.number("period", fallback: 30), 1)
      func totp(_ time: Double) async -> String {
        (try? await store.perform([
          "op": .string("totp"), "secret": .string(item.string("secret")),
          "period": .number(period), "time": .number(time.rounded(.down)),
        ]).object["code"]?.string) ?? ""
      }
      while !Task.isCancelled {
        let now = Date().timeIntervalSince1970
        let next = MobileCodeRow.nextWindow(now: now, period: period)
        code = await totp(now)
        nextCode = code.isEmpty ? "" : await totp(next.time)
        nextIn = next.remaining
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
      }
    }
  }
  @ViewBuilder private func value(
    _ label: String, _ value: String, key: String, secret: Bool = false,
    confirm: Bool = false, copyable: Bool = true
  ) -> some View {
    if !value.isEmpty {
      // Confirmed secrets stay hidden while the screen is recorded or mirrored.
      let hiddenByCapture = confirm && screenCaptured
      let shown = !secret || (revealing.contains(key) && !hiddenByCapture)
      VStack(alignment: .leading, spacing: 8) {
        Text(label).font(.caption).foregroundStyle(.secondary)
        if shown && !copyable {
          Text(value).font(.body.monospaced())
        } else {
          Text(shown ? value : "••••••••••••").font(.body.monospaced()).textSelection(.enabled)
        }
        if hiddenByCapture && revealing.contains(key) {
          Text(store.t("正在录屏或投屏，已隐藏。", "Hidden while the screen is recorded or mirrored."))
            .font(.caption).foregroundStyle(.orange)
        }
        HStack {
          if secret {
            Button(revealing.contains(key) ? store.t("隐藏", "Hide") : store.t("显示", "Show")) {
              if revealing.contains(key) { revealing.remove(key) }
              else if confirm { confirmingReveal = key }
              else { revealing.insert(key) }
            }
          }
          if copyable { Button(store.t("复制", "Copy")) { store.copy(value) } }
        }.buttonStyle(.bordered).controlSize(.regular)
        if !copyable {
          Text(store.t("助记词不支持复制，请抄写在离线介质上。", "Recovery phrases can't be copied; write them down offline."))
            .font(.caption).foregroundStyle(.secondary)
        }
      }.padding(.vertical, 4)
    }
  }
}
