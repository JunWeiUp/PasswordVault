import SwiftUI

struct RecoveryDraftReviewRow: Identifiable {
  let id = UUID()
  let draft: VaultItem
  let current: VaultItem?
  let currentLibraryName: String
  let blocked: String?
  var canRestore: Bool { blocked == nil }

  static func sameLibrary(_ draft: VaultItem, _ current: VaultItem) -> Bool {
    guard draft.string("sharedVaultId") == current.string("sharedVaultId") else { return false }
    let left = draft.fields["_peerLibrary"], right = current.fields["_peerLibrary"]
    if left == nil && right == nil {
      return draft.fields["_peerBaseHeads"] == nil && current.fields["_peerBaseHeads"] == nil
    }
    guard let left, let right, !left.string.isEmpty, left.string == right.string,
      let oldHeads = draft.fields["_peerBaseHeads"], let newHeads = current.fields["_peerBaseHeads"],
      case .array = oldHeads, case .array = newHeads else { return false }
    return true
  }
  init(draft: VaultItem, document: VaultDocument) {
    self.draft = draft
    currentLibraryName = document.settings["_peerLibraryName"]?.string ?? ""
    current = document.items.first { $0.id == draft.id }
    guard let current else { blocked = "missing"; return }
    guard current.type == draft.type, !current.isDeleted else { blocked = "deleted"; return }
    guard Self.sameLibrary(draft, current), (document.settings["activePeerLibrary"]?.string ?? "").isEmpty || current.fields["_peerLibrary"] != nil else { blocked = "library"; return }
    if document.settings["_peerLibraryReadOnly"]?.bool == true ||
       (!(document.settings["activePeerLibrary"]?.string ?? "").isEmpty && !["admin", "editor"].contains(document.settings["_peerLibraryRole"]?.string ?? "")) {
      blocked = "permission"; return
    }
    if !current.string("sharedVaultId").isEmpty {
      let own = document.settings["sharingIdentity"]?.object["publicKey"]?.string ?? ""
      guard !own.isEmpty, document.sharedMembers.contains(where: {
        $0.object["vaultId"]?.string == current.string("sharedVaultId") && $0.object["userPublicKey"]?.string == own && ["owner", "editor"].contains($0.object["role"]?.string ?? "")
      }) else { blocked = "permission"; return }
    }
    blocked = nil
  }
}

struct RecoveryDraftReviewView: View {
  @EnvironmentObject private var store: AppStore
  @State private var confirmation: UUID?
  @State private var restoring = false
  @State private var revealing = false
  var body: some View {
    let selected = store.recoveryReviewRows.first { $0.id == confirmation }
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(store.t("审核加密恢复草稿", "Review encrypted recovery drafts")).font(.title2.bold())
        Spacer()
        Button(store.t("稍后处理", "Review later")) { store.recoveryReviewPresented = false }.disabled(store.recoveryReviewBusy)
        Button(store.t("锁定", "Lock")) { store.lock() }.disabled(store.recoveryReviewBusy)
      }
      Text(store.t("旧草稿未自动覆盖当前资料。审核期间保留原密文，暂时停用常规编辑；您仍可查看资料或稍后再处理。", "Old drafts have not automatically replaced current records. Their ciphertext is retained; regular editing is paused until review is complete. You may still read your vault or review later."))
      HStack {
        Button(store.t("重新读取当前版本", "Reload current versions")) { Task { await store.loadRecoveryReview() } }.disabled(store.recoveryReviewBusy)
        Button(store.t("按原基线重试恢复", "Retry original-base recovery")) { Task { await store.retryRecoveryWithoutRebase() } }.disabled(store.recoveryReviewBusy)
        Toggle(store.t("显示敏感字段", "Reveal sensitive fields"), isOn: $revealing).toggleStyle(.switch)
      }
      if let message = store.recoveryReviewError { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          ForEach(store.recoveryReviewRows) { row in
            VStack(alignment: .leading, spacing: 12) {
              Text(row.draft.title.isEmpty ? store.t("未命名条目", "Untitled entry") : row.draft.title).font(.headline)
              Text(store.t("审核时的资料库：", "Library at review: ") + (row.currentLibraryName.isEmpty ? store.t("个人资料库", "Personal vault") : row.currentLibraryName)).font(.caption).foregroundStyle(.secondary)
              if let reason = row.blocked { Text(reasonText(reason)).foregroundStyle(.orange) }
              HStack(alignment: .top, spacing: 16) {
                comparison(row.current, label: store.t("审核时的当前版本", "Current version at review"))
                comparison(row.draft, label: store.t("尚未恢复的草稿", "Unrestored draft"))
              }
              HStack {
                Button(store.t("用草稿创建新版本…", "Create a new version from draft…")) { restoring = true; confirmation = row.id }.disabled(!row.canRestore || store.recoveryReviewBusy)
                Button(store.t("保留当前版本…", "Keep current version…"), role: .destructive) { restoring = false; confirmation = row.id }.disabled(store.recoveryReviewBusy)
                if row.blocked == "library" || row.blocked == "missing" {
                  Button(store.t("返回草稿原资料库", "Return to draft's library")) { Task { await store.switchRecoveryLibrary(for: row.id) } }.disabled(store.recoveryReviewBusy)
                }
              }
              Divider()
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }.padding(24).frame(minWidth: 780, idealWidth: 920, minHeight: 560, idealHeight: 740)
      .interactiveDismissDisabled(store.recoveryReviewBusy)
      .confirmationDialog(restoring ? store.t("仅将此草稿保存为新版本？", "Save only this draft as a new version?") : store.t("仅丢弃此草稿并保留资料库现状？", "Discard only this draft and keep the vault unchanged?"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
        Button(restoring ? store.t("确认创建新版本", "Create new version") : store.t("确认丢弃此草稿", "Discard this draft"), role: restoring ? nil : .destructive) {
          guard let id = selected?.id else { return }; let applyDraft = restoring; confirmation = nil
          Task { if applyDraft { await store.restoreReviewedDraft(id) } else { await store.discardReviewedDraft(id) } }
        }
        Button(store.t("取消", "Cancel"), role: .cancel) { confirmation = nil }
      } message: {
        Text((selected?.draft.title ?? "") + "\n\n" + (restoring ? store.t("仅处理所选一条草稿，并保留当前条目的 ID 与附件归属。如未启用版本历史，将启用并升级资料格式以保留当前内容；旧客户端可能无法打开。审核后发生的新修改仍会拒绝本次写入。", "Only the selected draft is applied, preserving its item ID and attachment ownership. If history is not enabled, it will be enabled and the data format upgraded to retain current content; older clients may no longer open it. A change after review will still reject the write.") : store.t("仅从恢复文件中移除所选一条草稿，不修改当前条目。剩余草稿重新加密写入失败时，将保留原文件。", "Only the selected draft is removed from recovery; current records are unchanged. If resealing the remaining drafts fails, the original file is retained.")))
      }
  }
  private func comparison(_ item: VaultItem?, label: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label).font(.subheadline.bold())
      if let item {
        Text(item.title).textSelection(.enabled)
        Text(item.isDeleted ? store.t("状态：已删除", "State: deleted") : store.t("状态：保留", "State: retained")).foregroundStyle(.secondary)
        Text(item.string("updatedAt")).font(.caption).foregroundStyle(.secondary)
        ForEach(item.fields.keys.filter { !$0.hasPrefix("_") && !["id", "title", "updatedAt", "isDeleted", "passkeys", "importSource", "noteDocument"].contains($0) }.sorted(), id: \.self) { key in
          let safe = ["type", "category", "tags", "isFavorite", "isPinned", "noteFormat", "period"].contains(key)
          VStack(alignment: .leading, spacing: 3) {
            Text(fieldName(key)).font(.caption).foregroundStyle(.secondary)
            if safe || revealing {
              ScrollView { Text(displayValue(item, key: key)).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 150)
            } else { Text("••••••") }
          }
        }
        if item.isRichNote { Text(store.t("图文格式及附件引用将完整保留。", "Rich formatting and attachment references are retained in full.")).font(.caption) }
        if let keys = item.fields["passkeys"]?.array, !keys.isEmpty { Text("Passkeys: \(keys.count)").font(.caption) }
        if item.fields["importSource"] != nil { Text(store.t("原始导入数据保留（不展示密钥或附件字节）。", "Original import data retained; keys and attachment bytes are not displayed.")).font(.caption) }
      } else { Text(store.t("当前库中未找到对应条目。", "No corresponding record in the current library.")) }
    }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
  }
  private func displayValue(_ item: VaultItem, key: String) -> String {
    if key == "type" {
      let names = ["secureNote": ("笔记", "Note"), "password": ("账号", "Account"), "totp": ("验证器", "Authenticator"), "crypto": ("钱包", "Wallet"), "creditCard": ("银行卡", "Payment card"), "identity": ("身份资料", "Identity")]
      return names[item.type].map { store.t($0.0, $0.1) } ?? store.t("其他条目", "Other entry")
    }
    if key == "noteFormat" { return item.isRichNote ? store.t("图文笔记", "Rich note") : (item.string(key) == "markdown" ? "Markdown" : store.t("纯文本", "Plain text")) }
    if key == "isFavorite" || key == "isPinned" { return item.bool(key) ? store.t("是", "Yes") : store.t("否", "No") }
    return fieldValue(item.fields[key] ?? .null)
  }
  private func fieldValue(_ value: JSONValue) -> String {
    if case .string(let text) = value { return text }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }
  private func fieldName(_ key: String) -> String {
    let labels = ["note": ("笔记正文", "Note body"), "username": ("用户名", "Username"), "password": ("密码", "Password"), "url": ("网站", "Website"), "type": ("条目类型", "Item type"), "category": ("分类", "Category"), "tags": ("标签", "Tags"), "card": ("银行卡", "Payment card"), "identity": ("身份资料", "Identity"), "customFields": ("自定义字段", "Custom fields"), "accounts": ("附加账号", "Additional accounts"), "isFavorite": ("收藏", "Favorite"), "isPinned": ("置顶", "Pinned"), "noteFormat": ("笔记格式", "Note format"), "period": ("验证码间隔（秒）", "Code period (seconds)"), "secret": ("验证器密钥", "Authenticator secret"), "mnemonic": ("助记词", "Recovery phrase"), "privateKey": ("钱包私钥", "Wallet private key"), "address": ("钱包地址", "Wallet address"), "network": ("网络", "Network"), "noteOriginal": ("原始笔记", "Original note"), "passwordHistory": ("密码历史", "Password history"), "createdAt": ("创建时间", "Created"), "email": ("邮箱", "Email")]
    return labels[key].map { store.t($0.0, $0.1) } ?? key
  }
  private func reasonText(_ reason: String) -> String {
    switch reason {
    case "library": return store.t("资料库标识不匹配或缺失，不能直接恢复到当前库。请返回原库或保留草稿。", "The library marker differs or is missing. Return to the original library or retain the draft; it cannot be applied here.")
    case "missing": return store.t("当前库没有对应条目，不能用同 ID 任意创建替代目标。请确认原库，或按原基线安全重试。", "The corresponding record is missing. No arbitrary replacement is created with its ID. Check the original library or retry the original base.")
    case "deleted": return store.t("当前条目已删除或类型不同，不能直接用此草稿替代。", "The current record is deleted or has a different type; this draft cannot replace it directly.")
    default: return store.t("当前资料库只读、被冻结或权限已撤销；草稿仍保留。", "The library is read-only, frozen or access was revoked; the draft is retained.")
    }
  }
}
