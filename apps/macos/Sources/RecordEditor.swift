import SwiftUI

struct RecordEditor: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  private let original: VaultItem
  private let isNew: Bool
  @State private var draft: VaultItem
  @State private var tags: String
  @State private var saving = false
  @State private var scanPresented = false
  @State private var inlineError: String?
  @FocusState private var titleFocused: Bool

  init(item: VaultItem, isNew: Bool = false) {
    original = item
    self.isNew = isNew
    _draft = State(initialValue: item)
    _tags = State(initialValue: item.tags.joined(separator: ", "))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(editorTitle).font(
          .title3.weight(.semibold))
        Spacer()
        Button(store.t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(
          saving)
        Button(store.t("保存", "Save"), action: save).buttonStyle(VaultButtonStyle(.primary)).tint(
          Palette.blue
        )
        .keyboardShortcut(.defaultAction).disabled(
          saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.padding(22)
      if let inlineError {
        Text(inlineError).font(.callout).foregroundStyle(.red).padding(.horizontal, 22).padding(
          .bottom, 12)
      }
      Divider()
      Form {
        Section {
          TextField(store.t("标题", "Title"), text: binding("title")).focused($titleFocused)
          HStack {
            TextField(store.t("分类", "Category"), text: binding("category"))
            Menu(store.t("选择已有分类", "Choose category")) {
              Button(store.t("无分类", "Uncategorized")) { draft.category = "" }
              ForEach(availableCategories, id: \.self) { name in
                Button(name) { draft.category = name }
              }
            }.menuStyle(.borderlessButton).foregroundStyle(Palette.accent).fixedSize()
              .vaultHoverFeedback()
          }
          TextField(store.t("标签（逗号分隔）", "Tags (comma separated)"), text: $tags)
          Picker(store.t("所属资料库", "Vault"), selection: binding("sharedVaultId")) {
            Text(store.t("个人资料库", "Personal vault")).tag("")
            ForEach(store.sharedVaults, id: \.self) { vault in
              Text(vault.object["name"]?.string ?? "").tag(vault.object["id"]?.string ?? "")
            }
          }
        }
        if draft.type == "password" {
          Section(store.t("账号信息", "Credentials")) {
            TextField(store.t("用户名", "Username"), text: binding("username"))
            SecureField(store.t("密码", "Password"), text: binding("password"))
            Button(store.t("生成随机密码", "Generate password")) {
              Task {
                do {
                  let value = try await store.perform([
                    "op": .string("generate"), "length": .number(20),
                  ])
                  draft.password = value.object["password"]?.string ?? ""
                } catch { inlineError = store.errorMessage(error) }
              }
            }
            TextField(store.t("网站", "Website"), text: binding("url"))
            TextField(store.t("邮箱", "Email"), text: binding("email"))
            TextField(
              store.t("密码有效期（天，0 为不限）", "Password duration (days; 0 means no expiry)"),
              value: Binding(
                get: { Int(draft.number("passwordDuration", fallback: 0)) },
                set: { draft.fields["passwordDuration"] = .number(Double(max(0, $0))) }),
              format: .number)
          }
          AdditionalAccountsEditor(
            accounts: Binding(
              get: { draft.fields["accounts"]?.array ?? [] },
              set: { draft.fields["accounts"] = .array($0) }))
        } else if draft.type == "totp" {
          Section(store.t("验证器", "Authenticator")) {
            TextField(store.t("账号", "Account"), text: binding("username"))
            SecureField(store.t("设置密钥", "Setup key"), text: binding("secret"))
            TextField(
              store.t("刷新间隔（秒）", "Period (seconds)"),
              value: Binding(
                get: { Int(draft.number("period", fallback: 30)) },
                set: { draft.fields["period"] = .number(Double($0)) }), format: .number)
            Button(store.t("扫描或导入二维码", "Scan or import QR code")) { scanPresented = true }
          }
        } else if draft.type == "crypto" {
          Section(store.t("钱包凭据", "Wallet credentials")) {
            TextField(store.t("网络", "Network"), text: binding("network"))
            HStack {
              Button(store.t("生成 ETH 助记词", "Generate ETH recovery phrase")) {
                Task { await deriveWallet(generate: true) }
              }
              Button(store.t("推导 ETH 地址", "Derive ETH address")) {
                Task { await deriveWallet(generate: false) }
              }
            }
            TextField(store.t("地址", "Address"), text: binding("address"))
            SecureField(store.t("私钥", "Private key"), text: binding("privateKey"))
            SecureField(store.t("助记词", "Recovery phrase"), text: binding("mnemonic"))
          }
        }
        Section(store.t("备注", "Notes")) { TextEditor(text: binding("note")).frame(minHeight: 150) }
      }.formStyle(.grouped).disabled(saving)
    }.frame(width: 620, height: 620)
      .onAppear { titleFocused = isNew }
      .interactiveDismissDisabled(saving)
      .sheet(isPresented: $scanPresented) {
        QRImportView { result in
          draft.title = result.title
          draft.username = result.username
          draft.set("secret", result.string("secret"))
          draft.fields["period"] = result.fields["period"]
        }
      }
  }

  private var editorTitle: String {
    guard isNew else { return store.t("编辑条目", "Edit entry") }
    switch draft.type {
    case "password": return store.t("新建密码", "New password")
    case "totp": return store.t("新建验证码", "New authenticator")
    case "crypto": return store.t("新建钱包", "New wallet")
    default: return store.t("新建条目", "New entry")
    }
  }

  private var availableCategories: [String] {
    if draft.type == "secureNote" { return store.categories }
    return Array(
      Set(store.items.filter { $0.type == draft.type && !$0.category.isEmpty }.map(\.category))
    ).sorted()
  }

  private func deriveWallet(generate: Bool) async {
    do {
      let result = try await store.perform([
        "op": .string("wallet"), "generate": .bool(generate),
        "mnemonic": .string(draft.string("mnemonic")),
        "privateKey": .string(draft.string("privateKey")),
      ])
      for key in ["mnemonic", "privateKey", "address", "network"] {
        if let value = result.object[key]?.string, !value.isEmpty { draft.set(key, value) }
      }
    } catch {
      inlineError = store.t(
        "助记词或私钥格式不正确，请检查后重试。", "The recovery phrase or private key is invalid. Check it and retry.")
    }
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { draft.string(key) }, set: { draft.set(key, $0) })
  }
  private func save() {
    guard !saving else { return }
    inlineError = nil
    if draft.type == "password" && draft.username.isEmpty && draft.password.isEmpty {
      inlineError = store.t(
        "请填写账号或密码。纯文本信息可以保存为笔记。", "Enter an account name or password. Use a note for plain text.")
      return
    }
    if draft.type == "crypto"
      && ["address", "privateKey", "mnemonic"].allSatisfy({
        draft.string($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    {
      inlineError = store.t(
        "请填写地址、私钥或助记词中的一项。", "Enter an address, private key, or recovery phrase.")
      return
    }
    saving = true
    draft.tags = tags.replacingOccurrences(of: "，", with: ",").split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    if draft.password != original.password && !original.password.isEmpty {
      var history = original.fields["passwordHistory"]?.array ?? []
      history.insert(
        .object([
          "password": .string(original.password),
          "changedAt": .string(ISO8601DateFormatter().string(from: Date())),
        ]), at: 0)
      draft.fields["passwordHistory"] = .array(history)
      draft.set("passwordLastChanged", ISO8601DateFormatter().string(from: Date()))
    }
    if let accounts = draft.fields["accounts"]?.array {
      let previous = original.fields["accounts"]?.array ?? []
      draft.fields["accounts"] = .array(
        accounts.map { entry in
          var fields = entry.object
          if let old = previous.first(where: { $0.object["id"] == fields["id"] }),
            old.object["password"] != fields["password"], let password = old.object["password"],
            !password.string.isEmpty
          {
            var history = old.object["passwordHistory"]?.array ?? []
            history.insert(
              .object([
                "password": password,
                "changedAt": .string(ISO8601DateFormatter().string(from: Date())),
              ]), at: 0)
            fields["passwordHistory"] = .array(history)
            fields["passwordLastChanged"] = .string(ISO8601DateFormatter().string(from: Date()))
          }
          return .object(fields)
        })
    }
    Task {
      defer { saving = false }
      if draft.type == "totp" {
        do {
          _ = try await store.perform([
            "op": .string("totp"), "secret": .string(draft.string("secret")),
            "period": .number(draft.number("period", fallback: 30)),
            "time": .number(Date().timeIntervalSince1970.rounded(.down)),
          ])
        } catch {
          inlineError = store.t(
            "验证器密钥或刷新间隔无效。请使用 Base32 密钥和 1–86400 秒间隔。",
            "The authenticator key or period is invalid. Use a Base32 key and a period from 1 to 86400 seconds."
          )
          return
        }
      }
      do {
        try await store.saveRecord(draft)
        store.selectedID = draft.id
        store.search = ""
        dismiss()
        store.showToast(store.t("条目已保存", "Entry saved"))
      } catch { inlineError = store.errorMessage(error, context: .save) }
    }
  }
}

private struct AdditionalAccountsEditor: View {
  @EnvironmentObject private var store: AppStore
  @Binding var accounts: [JSONValue]
  var body: some View {
    Section(store.t("其他账号", "Additional accounts")) {
      ForEach(accounts.indices, id: \.self) { index in
        VStack(alignment: .leading, spacing: 8) {
          TextField(store.t("名称", "Label"), text: binding(index, "label"))
          TextField(store.t("用户名", "Username"), text: binding(index, "username"))
          SecureField(store.t("密码", "Password"), text: binding(index, "password"))
          Button(store.t("移除账号", "Remove account"), role: .destructive) {
            accounts.remove(at: index)
          }
        }.padding(.vertical, 8)
      }
      Button(store.t("添加账号", "Add account")) {
        accounts.append(
          .object([
            "id": .string(UUID().uuidString), "label": .string(""), "username": .string(""),
            "password": .string(""),
          ]))
      }
    }
  }
  private func binding(_ index: Int, _ key: String) -> Binding<String> {
    Binding(
      get: { accounts.indices.contains(index) ? accounts[index].object[key]?.string ?? "" : "" },
      set: { value in
        guard accounts.indices.contains(index) else { return }
        var record = accounts[index].object
        record[key] = .string(value)
        accounts[index] = .object(record)
      })
  }
}
