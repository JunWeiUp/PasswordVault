import SwiftUI

struct MobileEntryDetail: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let id: String
  @State private var editor: VaultItem?
  @State private var revealing = Set<String>()
  @State private var deleting = false
  @State private var code = ""
  private var item: VaultItem? { store.items.first { $0.id == id } }
  var body: some View {
    Group {
      if let item {
        List {
          Section {
            Text(item.title).font(.title2.bold())
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
              Text(code.isEmpty ? "—— ——" : code).font(
                .system(size: 36, weight: .medium, design: .monospaced))
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
                secret: true)
              value(
                store.t("助记词", "Recovery phrase"), item.string("mnemonic"), key: "mnemonic",
                secret: true)
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
              MobileMarkdown(source: item.note)
            }
          }
          if !store.canEdit(item) {
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
    .sheet(item: $editor) { MobileEntryEditor(item: $0) }
    .task(id: item) {
      guard let item, item.type == "totp" else { return }
      while !Task.isCancelled {
        code =
          (try? await store.perform([
            "op": .string("totp"), "secret": .string(item.string("secret")),
            "period": .number(item.number("period", fallback: 30)),
            "time": .number(Date().timeIntervalSince1970.rounded(.down)),
          ]).object["code"]?.string) ?? ""
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
      }
    }
  }
  @ViewBuilder private func value(
    _ label: String, _ value: String, key: String, secret: Bool = false
  ) -> some View {
    if !value.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(label).font(.caption).foregroundStyle(.secondary)
        Text(secret && !revealing.contains(key) ? "••••••••••••" : value).font(.body.monospaced())
          .textSelection(.enabled)
        HStack {
          if secret {
            Button(revealing.contains(key) ? store.t("隐藏", "Hide") : store.t("显示", "Show")) {
              if revealing.contains(key) { revealing.remove(key) } else { revealing.insert(key) }
            }
          }
          Button(store.t("复制", "Copy")) { store.copy(value) }
        }.buttonStyle(.bordered).controlSize(.regular)
      }.padding(.vertical, 4)
    }
  }
}
