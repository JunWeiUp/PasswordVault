import SwiftUI

struct MobileEntryEditor: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let original: VaultItem
  let recovered: Bool
  @State private var draft: VaultItem
  @State private var tags: String
  @State private var saving = false
  @State private var discard = false
  @State private var replaceWallet = false
  @State private var uri = ""
  @State private var scanning = false
  @State private var message: String?
  init(item: VaultItem, recovered: Bool = false) {
    self.recovered = recovered
    original = item
    _draft = State(initialValue: item)
    _tags = State(initialValue: item.tags.joined(separator: ", "))
  }
  private var changed: Bool {
    recovered || draft != original || tags != original.tags.joined(separator: ", ")
  }
  private func field(_ key: String) -> Binding<String> {
    Binding(get: { draft.string(key) }, set: { draft.set(key, $0) })
  }
  var body: some View {
    NavigationStack {
      Form {
        if let message { Section { Text(message).foregroundStyle(.red) } }
        Section {
          TextField(store.t("标题", "Title"), text: field("title")).accessibilityIdentifier(
            "entry.title")
          TextField(store.t("分类", "Category"), text: field("category"))
          if !store.sharedVaults.isEmpty {
            Picker(store.t("所属资料库", "Vault"), selection: field("sharedVaultId")) {
              Text(store.t("个人资料库", "Personal vault")).tag("")
              ForEach(store.sharedVaults, id: \.self) {
                Text($0.object["name"]?.string ?? "").tag($0.object["id"]?.string ?? "")
              }
            }
          }
          TextField(store.t("标签，逗号分隔", "Tags, comma separated"), text: $tags)
        }
        if draft.type == "password" {
          Section(store.t("账号信息", "Credentials")) {
            TextField(store.t("用户名", "Username"), text: field("username"))
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(store.t("密码", "Password"), text: field("password")).textContentType(
              .newPassword)
            TextField(store.t("网站", "Website"), text: field("url")).keyboardType(.URL)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(store.t("生成随机密码", "Generate password")) {
              Task {
                do {
                  draft.password =
                    try await store.perform(["op": .string("generate"), "length": .number(20)])
                    .object["password"]?.string ?? ""
                } catch { message = store.t("无法生成，请重试", "Could not generate; retry") }
              }
            }
          }
          Section(store.t("更多账号", "Additional accounts")) {
            ForEach(Array((draft.fields["accounts"]?.array ?? []).enumerated()), id: \.offset) {
              index, _ in
              VStack(alignment: .leading) {
                TextField(store.t("用户名", "Username"), text: account(index, "username"))
                  .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(store.t("密码", "Password"), text: account(index, "password"))
                Button(store.t("移除此账号", "Remove account"), role: .destructive) {
                  var values = draft.fields["accounts"]?.array ?? []
                  values.remove(at: index)
                  draft.fields["accounts"] = .array(values)
                }
              }
            }
            Button(store.t("添加账号", "Add account")) {
              var values = draft.fields["accounts"]?.array ?? []
              values.append(
                .object([
                  "id": .string(UUID().uuidString), "username": .string(""),
                  "password": .string(""),
                ]))
              draft.fields["accounts"] = .array(values)
            }
          }
        } else if draft.type == "totp" {
          Section(store.t("验证器", "Authenticator")) {
            TextField(store.t("账号", "Account"), text: field("username"))
            SecureField(store.t("设置密钥", "Setup key"), text: field("secret"))
            Stepper(
              "\(store.t("刷新间隔", "Period")): \(Int(draft.number("period", fallback: 30))) s",
              value: Binding(
                get: { Int(draft.number("period", fallback: 30)) },
                set: { draft.fields["period"] = .number(Double($0)) }), in: 1...86400)
            Button(store.t("扫描 / 导入二维码", "Scan / import QR")) { scanning = true }
            TextField("otpauth://…", text: $uri).textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Button(store.t("导入设置链接", "Import setup link")) {
              Task {
                do {
                  let result = try await store.perform([
                    "op": .string("parse-totp"), "uri": .string(uri),
                  ]).object
                  for key in ["title", "username", "secret", "period"] {
                    if let value = result[key] { draft.fields[key] = value }
                  }
                  uri = ""
                } catch { message = store.t("设置链接无效", "Invalid setup link") }
              }
            }
          }
        } else if draft.type == "crypto" {
          Section(store.t("钱包凭据", "Wallet credentials")) {
            TextField(store.t("网络", "Network"), text: field("network"))
            TextField(store.t("地址", "Address"), text: field("address")).textInputAutocapitalization(
              .never
            ).autocorrectionDisabled()
            SecureField(store.t("私钥", "Private key"), text: field("privateKey"))
            SecureField(store.t("助记词", "Recovery phrase"), text: field("mnemonic"))
            Button(store.t("推导 ETH 地址", "Derive ETH address")) { derive(false) }
            Button(store.t("生成 ETH 钱包", "Generate ETH wallet")) {
              if ["address", "privateKey", "mnemonic"].contains(where: { !draft.string($0).isEmpty }
              ) {
                replaceWallet = true
              } else {
                derive(true)
              }
            }
          }
        }
        Section(store.t("备注 / Markdown", "Notes / Markdown")) {
          TextEditor(text: field("note")).frame(minHeight: 180).accessibilityLabel(
            store.t("备注", "Notes"))
        }
      }
      .navigationTitle(store.t("编辑条目", "Edit entry")).navigationBarTitleDisplayMode(.inline)
      .disabled(saving)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(store.t("取消", "Cancel")) {
            if changed {
              discard = true
            } else {
              store.discardDraft()
              dismiss()
            }
          }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(store.t("保存", "Save")) { save() }.disabled(
            saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .sheet(isPresented: $scanning) {
        MobileQRImport { result in
          for key in ["title", "username", "secret", "period"] {
            if let value = result[key] { draft.fields[key] = value }
          }
        }
      }
      .interactiveDismissDisabled(changed || saving)
      .onChange(of: draft) {
        store.pendingDraft = $0
        store.activity()
      }
      .onChange(of: tags) { value in
        store.activity()
        var pending = draft
        pending.tags = value.split(separator: ",").map(String.init)
        store.pendingDraft = pending
      }
      .confirmationDialog(
        store.t("放弃未保存的修改？", "Discard unsaved changes?"), isPresented: $discard,
        titleVisibility: .visible
      ) {
        Button(store.t("放弃修改", "Discard changes"), role: .destructive) {
          store.discardDraft()
          dismiss()
        }
        Button(store.t("继续编辑", "Keep editing"), role: .cancel) {}
      }
      .confirmationDialog(
        store.t("替换当前草稿的钱包凭据？", "Replace this draft’s wallet credentials?"),
        isPresented: $replaceWallet, titleVisibility: .visible
      ) {
        Button(store.t("生成并替换", "Generate and replace"), role: .destructive) { derive(true) }
      } message: {
        Text(
          store.t(
            "将替换地址、私钥和助记词，保存前不会改变原记录。",
            "Replaces the address, private key and phrase. The original record changes only when saved."
          ))
      }
    }
  }
  private func account(_ index: Int, _ key: String) -> Binding<String> {
    Binding(
      get: {
        let values = draft.fields["accounts"]?.array ?? []
        return values.indices.contains(index) ? values[index].object[key]?.string ?? "" : ""
      },
      set: { value in
        var values = draft.fields["accounts"]?.array ?? []
        guard values.indices.contains(index) else { return }
        var entry = values[index].object
        entry[key] = .string(value)
        values[index] = .object(entry)
        draft.fields["accounts"] = .array(values)
      })
  }
  private func derive(_ generate: Bool) {
    Task {
      do {
        let result = try await store.perform([
          "op": .string("wallet"), "generate": .bool(generate),
          "mnemonic": .string(draft.string("mnemonic")),
          "privateKey": .string(draft.string("privateKey")),
        ])
        for key in ["network", "address", "privateKey", "mnemonic"] {
          if let value = result.object[key], !value.string.isEmpty { draft.fields[key] = value }
        }
      } catch { message = store.t("钱包凭据格式无效。", "Invalid wallet credentials.") }
    }
  }
  private func save() {
    saving = true
    message = nil
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
          message = store.t("设置密钥或间隔无效。", "Invalid setup key or period.")
          return
        }
      }
      draft.tags = tags.replacingOccurrences(of: "，", with: ",").split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty }
      var value = draft
      if value.password != original.password && !original.password.isEmpty {
        var history = original.fields["passwordHistory"]?.array ?? []
        history.insert(
          .object([
            "password": .string(original.password),
            "changedAt": .string(ISO8601DateFormatter().string(from: Date())),
          ]), at: 0)
        value.fields["passwordHistory"] = .array(history)
      }
      if value.password != original.password {
        value.set("passwordLastChanged", ISO8601DateFormatter().string(from: Date()))
      }
      if let accounts = value.fields["accounts"]?.array {
        let previous = original.fields["accounts"]?.array ?? []
        value.fields["accounts"] = .array(
          accounts.map { account in
            var fields = account.object
            if let old = previous.first(where: { $0.object["id"] == fields["id"] }),
              old.object["password"] != fields["password"]
            {
              var history = old.object["passwordHistory"]?.array ?? []
              if let password = old.object["password"], !password.string.isEmpty {
                history.insert(
                  .object([
                    "password": password,
                    "changedAt": .string(ISO8601DateFormatter().string(from: Date())),
                  ]), at: 0)
              }
              fields["passwordHistory"] = .array(history)
              fields["passwordLastChanged"] = .string(ISO8601DateFormatter().string(from: Date()))
            }
            return .object(fields)
          })
      }
      if await store.save(value) {
        store.discardDraft()
        dismiss()
      } else {
        message = store.error
        store.error = nil
      }
    }
  }
}
