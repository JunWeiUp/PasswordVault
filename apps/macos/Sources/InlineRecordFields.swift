import AppKit
import SwiftUI

struct InlineRecordFields: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  @State private var operationID = UUID()
  @State private var message: String?
  @State private var busy = false
  @State private var scan = false
  @State private var setupURI = ""
  @State private var removeAccount: String?
  @State private var replaceWallet = false
  @State private var clearCode = false
  private var editable: Bool { store.canEdit(item) }
  private var credential: Bool { ["password", "totp"].contains(item.type) }
  private var current: VaultItem { store.items.first { $0.id == item.id } ?? item }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      if busy { ProgressView(store.t("正在处理…", "Working…")).controlSize(.small) }
      if let message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
      if credential {
        EntrySection(store.t("账号信息", "Credentials")) {
          InlineEntryField(title: store.t("用户名", "Username"), text: field("username"), editable: editable)
          InlineEntryField(title: store.t("密码", "Password"), text: field("password"), secret: true, editable: editable, generate: { generatePassword() })
          EntryHistoryView(fields: current.fields)
        }.id("primary-account")
        EntrySection(store.t("附加账号", "Additional accounts")) {
          ForEach(accountRows) { row in
            let offset = row.index, account = row.account
            let id = account.object["id"]?.string ?? ""
            HStack {
              Text(account.object["label"]?.string.isEmpty == false ? account.object["label"]!.string : store.t("其他账号", "Additional account")).font(.headline)
              Spacer()
              Button(store.t("移除", "Remove"), role: .destructive) { removeAccount = id }.disabled(!editable)
            }.id(row.id)
            InlineEntryField(title: store.t("用途", "Purpose"), text: accountField(id, "label", fallback: offset), editable: editable, copyable: false)
            InlineEntryField(title: store.t("用户名", "Username"), text: accountField(id, "username", fallback: offset), editable: editable)
            InlineEntryField(title: store.t("密码", "Password"), text: accountField(id, "password", fallback: offset), secret: true, editable: editable, generate: { generatePassword(id) })
            EntryHistoryView(fields: account.object)
            Divider()
          }
          Button { mutate { entry in
            var accounts = entry.fields["accounts"]?.array ?? []
            accounts.append(.object(["id": .string(UUID().uuidString), "label": .string(""), "username": .string(""), "password": .string("")]))
            entry.fields["accounts"] = .array(accounts)
          } } label: { Label(store.t("添加另一个账号", "Add another account"), systemImage: "plus") }.disabled(!editable)
        }
        EntrySection(store.t(item.type == "totp" ? "验证码设置" : "二次验证", item.type == "totp" ? "Authenticator" : "Two-step verification")) {
          InlineCodePreview(item: current)
          InlineEntryField(title: store.t("设置密钥", "Setup key"), text: Binding(get: { current.string("secret") }, set: { value in mutate { $0.set("secret", value.replacingOccurrences(of: " ", with: "").uppercased()) } }), secret: true, editable: editable)
          HStack {
            Text(store.t("刷新间隔（秒）", "Period (seconds)"))
            TextField("30", value: Binding(get: { Int(current.number("period", fallback: 30)) }, set: { value in if (1...86400).contains(value) { mutate { $0.fields["period"] = .number(Double(value)) } } }), format: .number).frame(width: 100).disabled(!editable)
          }
          InlineEntryField(title: store.t("设置链接", "Setup link"), text: $setupURI, secret: true, editable: editable, copyable: false)
          HStack {
            Button(store.t("导入链接", "Import link")) { parseURI() }.disabled(!editable || setupURI.isEmpty || busy)
            Button(store.t("扫描 / 图片导入…", "Scan / import image…")) { scan = true }.disabled(!editable || busy)
            Button(store.t("复制设置链接", "Copy setup link")) { store.copy(setupLink) }.disabled(current.string("secret").isEmpty)
            Spacer()
            Button(store.t("清除", "Clear"), role: .destructive) { clearCode = true }.disabled(!editable || current.string("secret").isEmpty)
          }
        }
      } else if item.type == "crypto" {
        EntrySection(store.t("钱包信息", "Wallet credentials")) {
          InlineEntryField(title: store.t("地址", "Address"), text: field("address"), editable: editable, multiline: true)
          entryChoice(store.t("网络", "Network"), key: "network", defaults: ["ETH", "BTC", "BSC", "Polygon", "Solana", "TRON", "AVAX", "Arbitrum", "Optimism"])
          InlineEntryField(title: store.t("私钥", "Private key"), text: field("privateKey"), secret: true, editable: editable)
          Button(store.t("根据私钥更新 ETH 地址", "Update ETH address from private key")) { deriveWallet("privateKey") }.disabled(!editable || busy || current.string("privateKey").isEmpty)
        }
        EntrySection(store.t("助记词", "Recovery phrase")) {
          RecoveryPhraseEditor(text: field("mnemonic"), editable: editable)
          HStack {
            Button(store.t("根据助记词更新私钥和地址", "Update key and address from phrase")) { deriveWallet("mnemonic") }.disabled(!editable || busy || current.string("mnemonic").trimmingCharacters(in: .whitespaces).isEmpty)
            Button(store.t("生成 ETH 钱包", "Generate ETH wallet")) {
              if ["address", "privateKey", "mnemonic"].contains(where: { !current.string($0).isEmpty }) { replaceWallet = true }
              else { deriveWallet("generate") }
            }.disabled(!editable || busy)
          }
        }
      }
      EntrySection(store.t("更多信息", "More information")) {
        if credential {
          InlineEntryField(title: store.t("邮箱", "Email"), text: field("email"), editable: editable)
          InlineEntryField(title: store.t("网站 / 域名（支持多个）", "Websites / domains (multiple supported)"), text: field("url"), editable: editable, multiline: true)
          if !websiteURLs.isEmpty {
            Menu(store.t("打开网站", "Open website")) {
              ForEach(websiteURLs, id: \.absoluteString) { url in
                Button(url.absoluteString) { NSWorkspace.shared.open(url) }
              }
            }.buttonStyle(.automatic)
          }
          HStack {
            Text(store.t("密码有效期（天，0 为不限）", "Password duration (days, 0 for no expiry)"))
            TextField("0", value: Binding(get: { Int(current.number("passwordDuration")) }, set: { value in if value >= 0 { mutate { $0.fields["passwordDuration"] = .number(Double(value)) } } }), format: .number).frame(width: 100).disabled(!editable)
          }
        }
        InlineEntryField(title: store.t("备注", "Notes"), text: field("note"), editable: editable, multiline: true, copyable: false)
      }
      EntryMetadata(item: current)
    }
    .onAppear { store.normalizeEntryAccounts(item.id) }
    .onDisappear { operationID = UUID() }
    .sheet(isPresented: $scan) { QRImportView { candidate in applyCode(candidate.fields) } }
    .confirmationDialog(store.t("移除此附加账号？", "Remove this additional account?"), isPresented: Binding(get: { removeAccount != nil }, set: { if !$0 { removeAccount = nil } })) {
      Button(store.t("移除", "Remove"), role: .destructive) {
        if let id = removeAccount { mutate { $0.fields["accounts"] = .array(($0.fields["accounts"]?.array ?? []).filter { $0.object["id"]?.string != id }) } }
        removeAccount = nil
      }
    }
    .confirmationDialog(store.t("替换当前钱包凭据？", "Replace current wallet credentials?"), isPresented: $replaceWallet) {
      Button(store.t("生成并替换", "Generate and replace"), role: .destructive) { deriveWallet("generate") }
    } message: { Text(store.t("请先确保已备份当前私钥和助记词。", "Make sure the current key and recovery phrase are backed up.")) }
    .confirmationDialog(store.t("清除二次验证设置？", "Clear authenticator settings?"), isPresented: $clearCode) {
      Button(store.t("清除", "Clear"), role: .destructive) { mutate { $0.set("secret", ""); $0.fields["period"] = .number(30) } }
    }
  }

  private struct AccountRow: Identifiable {
    let id: String
    let index: Int
    let account: JSONValue
  }
  private var accountRows: [AccountRow] {
    let accounts = current.fields["accounts"]?.array ?? []
    let ids = accounts.map { $0.object["id"]?.string ?? "" }
    return accounts.enumerated().map { index, account in
      let id = ids[index]
      return AccountRow(id: !id.isEmpty && ids.filter { $0 == id }.count == 1 ? "account:" + id : "legacy:" + String(index), index: index, account: account)
    }
  }
  private func field(_ key: String) -> Binding<String> { Binding(get: { current.string(key) }, set: { value in mutate { $0.set(key, value) } }) }
  private func mutate(_ change: (inout VaultItem) -> Void) {
    guard editable else { return }
    var next = current; change(&next); store.editEntry(next)
  }
  private func accountField(_ id: String, _ key: String, fallback: Int? = nil) -> Binding<String> {
    Binding(get: {
      let accounts = current.fields["accounts"]?.array ?? []
      if let fallback, accounts.indices.contains(fallback) { return accounts[fallback].object[key]?.string ?? "" }
      return accounts.first { $0.object["id"]?.string == id }?.object[key]?.string ?? ""
    }, set: { value in mutate { record in
      record.fields["accounts"] = .array((record.fields["accounts"]?.array ?? []).map { account in
        guard account.object["id"]?.string == id else { return account }
        var fields = account.object; fields[key] = .string(value); return .object(fields)
      })
    } })
  }
  private func generatePassword(_ accountID: String? = nil) {
    guard !busy else { return }
    busy = true; message = nil; operationID = UUID()
    let snapshot = current, token = operationID
    Task {
      defer { if operationID == token { busy = false } }
      do {
        let value = try await store.perform(["op": .string("generate"), "length": .number(20)])
        guard operationID == token, store.selectedID == item.id, current == snapshot else { return }
        if let accountID { accountField(accountID, "password").wrappedValue = value.object["password"]?.string ?? "" }
        else { field("password").wrappedValue = value.object["password"]?.string ?? "" }
      } catch { if operationID == token { message = store.errorMessage(error) } }
    }
  }
  private func deriveWallet(_ source: String) {
    guard !busy else { return }
    busy = true; message = nil; operationID = UUID()
    let snapshot = current, token = operationID
    Task {
      defer { if operationID == token { busy = false } }
      do {
        let value = try await store.perform(["op": .string("wallet"), "generate": .bool(source == "generate"), "mnemonic": .string(source == "mnemonic" ? snapshot.string("mnemonic") : ""), "privateKey": .string(source == "privateKey" ? snapshot.string("privateKey") : "")])
        guard operationID == token, store.selectedID == item.id, current == snapshot else { return }
        mutate { next in
          for key in source == "privateKey" ? ["address", "network"] : ["address", "network", "privateKey", "mnemonic"] {
            if let field = value.object[key], !field.string.isEmpty { next.fields[key] = field }
          }
        }
      } catch { if operationID == token { message = store.t("输入格式无效，原有信息已保留。", "Invalid input; existing values were preserved.") } }
    }
  }
  private func parseURI() {
    operationID = UUID()
    let captured = setupURI, snapshot = current, token = operationID
    busy = true
    Task {
      defer { if operationID == token { busy = false } }
      do {
        let parsed = try await store.perform(["op": .string("parse-totp"), "uri": .string(captured)])
        guard operationID == token, store.selectedID == item.id, current == snapshot, setupURI == captured else { return }
        applyCode(parsed.object); setupURI = ""; message = nil
      } catch { if operationID == token { message = store.t("设置链接无效，请检查后重试。", "Invalid setup link; check and retry.") } }
    }
  }
  private func applyCode(_ fields: [String: JSONValue]) {
    guard store.selectedID == item.id else { return }
    mutate { next in
      if ["未命名验证码", "Untitled authenticator", "未命名账号", "Untitled account"].contains(next.title),
         let title = fields["title"]?.string, !title.isEmpty { next.title = title }
      for key in ["secret", "period"] { if let value = fields[key] { next.fields[key] = value } }
      if next.username.isEmpty { next.fields["username"] = fields["username"] }
    }
  }
  private var websiteURLs: [URL] {
    current.string("url").split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).compactMap { value in
      let raw = String(value)
      guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
      return url
    }
  }
  private var setupLink: String {
    var components = URLComponents()
    components.scheme = "otpauth"; components.host = "totp"; components.path = "/" + current.title + ":" + current.username
    components.queryItems = [URLQueryItem(name: "secret", value: current.string("secret")), URLQueryItem(name: "issuer", value: current.title), URLQueryItem(name: "period", value: String(Int(current.number("period", fallback: 30)))), URLQueryItem(name: "algorithm", value: "SHA1"), URLQueryItem(name: "digits", value: "6")]
    return components.string ?? ""
  }
  @ViewBuilder private func entryChoice(_ title: String, key: String, defaults: [String]) -> some View {
    HStack {
      InlineEntryField(title: title, text: field(key), editable: editable, copyable: false)
      Menu(store.t("选择", "Choose")) {
        ForEach(Array(Set(defaults + store.items.map { $0.string(key) })).filter { !$0.isEmpty }.sorted(), id: \.self) { value in Button(value) { field(key).wrappedValue = value } }
      }.buttonStyle(.automatic).disabled(!editable)
    }
  }
}

struct EntrySection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      Text(title).font(.headline).foregroundStyle(Palette.accent)
      content
    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
      .background(Palette.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct InlineEntryField: View {
  @EnvironmentObject private var store: AppStore
  let title: String
  @Binding var text: String
  var secret = false
  var editable = true
  var multiline = false
  var copyable = true
  var generate: (() -> Void)?
  @State private var revealed = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 10) {
        Group {
          if secret && !revealed { SecureField(title, text: $text) }
          else if multiline { TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 55, maxHeight: 100) }
          else { TextField(title, text: $text) }
        }.textFieldStyle(.plain).font(.system(size: 15, design: secret ? .monospaced : .default))
          .padding(9).background(Palette.surface, in: RoundedRectangle(cornerRadius: 6)).disabled(!editable)
          .accessibilityIdentifier("entry.field." + title)
        if secret { Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }.help(store.t("显示 / 隐藏", "Reveal / conceal")).accessibilityLabel(store.t("显示或隐藏", "Reveal or conceal") + title) }
        if copyable { Button { store.copy(text) } label: { Image(systemName: "doc.on.doc") }.disabled(text.isEmpty).accessibilityLabel(store.t("复制", "Copy") + title) }
        if let generate { Button(action: generate) { Image(systemName: "wand.and.stars") }.disabled(!editable).accessibilityLabel(store.t("生成", "Generate") + title) }
      }.buttonStyle(VaultButtonStyle(.plain))
    }
  }
}

struct EntryHistoryView: View {
  @EnvironmentObject private var store: AppStore
  let fields: [String: JSONValue]
  var body: some View {
    if let time = fields["passwordLastChanged"]?.string, !time.isEmpty {
      Text(store.t("上次修改：", "Last changed: ") + formatted(time)).font(.caption).foregroundStyle(.secondary)
    }
    if let history = fields["passwordHistory"]?.array, !history.isEmpty {
      DisclosureGroup(store.t("密码历史", "Password history") + " · \(history.count)") {
        ForEach(Array(history.enumerated()), id: \.offset) { _, record in
          ValueRow(title: formatted(record.object["changedAt"]?.string ?? ""), value: record.object["password"]?.string ?? "", secret: true)
        }
      }
    }
  }
  private func formatted(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

}

struct EntryMetadata: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  @State private var tag = ""
  private var editable: Bool { store.canEdit(item) }
  private var current: VaultItem { store.items.first { $0.id == item.id } ?? item }
  private func update(_ block: (inout VaultItem) -> Void) { var next = current; block(&next); store.editEntry(next) }
  private struct AccountRow: Identifiable {
    let id: String
    let index: Int
    let account: JSONValue
  }
  private var accountRows: [AccountRow] {
    let accounts = current.fields["accounts"]?.array ?? []
    let ids = accounts.map { $0.object["id"]?.string ?? "" }
    return accounts.enumerated().map { index, account in
      let id = ids[index]
      return AccountRow(id: !id.isEmpty && ids.filter { $0 == id }.count == 1 ? "account:" + id : "legacy:" + String(index), index: index, account: account)
    }
  }
  private func field(_ key: String) -> Binding<String> { Binding(get: { current.string(key) }, set: { value in update { $0.set(key, value) } }) }
  var body: some View {
    EntrySection(store.t("分类与显示", "Organization")) {
      HStack {
        InlineEntryField(title: store.t("分类", "Category"), text: field("category"), editable: editable, copyable: false)
        Menu(store.t("选择分类", "Choose category")) {
          Button(store.t("无分类", "Uncategorized")) { field("category").wrappedValue = "" }
          ForEach(Array(Set(["社交媒体", "财务", "工作", "购物", "娱乐", "加密资产", "笔记"] + store.items.map(\.category))).filter { !$0.isEmpty }.sorted(), id: \.self) { value in Button(value) { field("category").wrappedValue = value } }
        }.buttonStyle(.automatic).disabled(!editable)
      }
      Picker(store.t("所属资料库", "Vault"), selection: field("sharedVaultId")) {
        Text(store.t("个人资料库", "Personal vault")).tag("")
        ForEach(store.sharedVaults, id: \.self) { vault in
          let id = vault.object["id"]?.string ?? ""
          let writable = canMove(to: id)
          Text((vault.object["name"]?.string ?? "") + (writable ? "" : store.t(" · 只读", " · Read only"))).tag(id).disabled(!writable)
        }
      }.disabled(!editable)
      if !current.tags.isEmpty {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading) {
          ForEach(current.tags, id: \.self) { value in
            Button { update { $0.tags.removeAll { $0 == value } } } label: { Label(value, systemImage: "xmark.circle") }.disabled(!editable)
          }
        }
      }
      HStack {
        TextField(store.t("新标签", "New tag"), text: $tag).disabled(!editable).onSubmit(addTag)
        Button(store.t("添加标签", "Add tag"), action: addTag).disabled(!editable || tag.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      HStack {
        Toggle(store.t("置顶", "Pin"), isOn: Binding(get: { current.isPinned }, set: { value in update { $0.isPinned = value } }))
        Toggle(store.t("收藏", "Favorite"), isOn: Binding(get: { current.isFavorite }, set: { value in update { $0.isFavorite = value } }))
      }.disabled(!editable)
      Picker(store.t("颜色标记", "Color label"), selection: field("colorLabel")) {
        Text(store.t("无", "None")).tag("")
        ForEach(["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "粉色", "青色"], id: \.self) { Text($0).tag($0) }
      }.disabled(!editable)
    }
  }
  private func canMove(to id: String) -> Bool { var target = current; target.set("sharedVaultId", id); return store.canEdit(target) }
  private func addTag() { let value = tag.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty && !current.tags.contains(value) { update { $0.tags.append(value) } }; tag = "" }
}

struct InlineCodePreview: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  @State private var code = ""
  @State private var invalid = false
  var body: some View {
    if item.string("secret").isEmpty { Text(store.t("尚未配置验证码", "Authenticator not configured")).foregroundStyle(.secondary) }
    else {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let period = max(1, Int(item.number("period", fallback: 30)))
        let time = Int(context.date.timeIntervalSince1970)
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(code.isEmpty ? "——— ———" : code).font(.system(size: 27, weight: .medium, design: .monospaced))
            Button(store.t("复制验证码", "Copy code")) { store.copy(code) }.disabled(code.isEmpty)
          }
          if invalid { Text(store.t("密钥尚未完整或格式无效", "Key is incomplete or invalid")).foregroundStyle(.orange).font(.caption) }
          else { ProgressView(value: Double(period - time % period), total: Double(period)) }
        }.task(id: [item.string("secret"), String(period), String(time / period)]) {
          do {
            let result = try await store.perform(["op": .string("totp"), "secret": .string(item.string("secret")), "period": .number(Double(period)), "time": .number(Double(time))])
            guard !Task.isCancelled else { return }; code = result.object["code"]?.string ?? ""; invalid = false
          } catch { if !Task.isCancelled { code = ""; invalid = true } }
        }
      }
    }
  }
}

struct RecoveryPhraseEditor: View {
  @EnvironmentObject private var store: AppStore
  @Binding var text: String
  let editable: Bool
  @State private var revealed = false
  @FocusState private var focused: Int?
  private static let dictionary: [String] = {
    guard let url = Bundle.main.url(forResource: "bip39-english", withExtension: "txt"), let value = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return value.split(separator: "\n").map(String.init)
  }()
  private var words: [String] {
    let parsed = text.components(separatedBy: " ")
    return parsed + Array(repeating: "", count: max(0, 12 - parsed.count))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button(store.t(revealed ? "隐藏助记词" : "显示助记词", revealed ? "Hide phrase" : "Reveal phrase")) { revealed.toggle() }
        Button(store.t("复制整段", "Copy phrase")) { store.copy(text) }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        Button(store.t("粘贴整段", "Paste phrase")) { if let value = NSPasteboard.general.string(forType: .string) { setPhrase(value) } }.disabled(!editable)
      }
      if revealed {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], spacing: 8) {
          ForEach(words.indices, id: \.self) { index in
            HStack { Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 20)
              TextField("", text: Binding(get: { words.indices.contains(index) ? words[index] : "" }, set: { value in
                if value.split(whereSeparator: \.isWhitespace).count > 1 { setPhrase(value) }
                else { var next = words; next[index] = value.lowercased(); text = next.joined(separator: " ") }
              })).focused($focused, equals: index).disabled(!editable).accessibilityLabel(store.t("助记词", "Recovery word") + " \(index + 1)")
            }
          }
        }
        if let index = focused, words.indices.contains(index), words[index].count >= 2 {
          HStack {
            ForEach(Array(Self.dictionary.filter { $0.hasPrefix(words[index]) }.prefix(6)), id: \.self) { word in
              Button(word) { var next = words; next[index] = word; text = next.joined(separator: " ") }.disabled(!editable)
            }
          }
        }
        Button(store.t("扩展为 24 个词", "Expand to 24 words")) { if words.count < 24 { text = (words + Array(repeating: "", count: 24 - words.count)).joined(separator: " ") } }.disabled(!editable || words.count >= 24)
      } else { Text("••••  ••••  ••••  ••••").foregroundStyle(.secondary) }
    }
  }
  private func setPhrase(_ value: String) { text = value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
