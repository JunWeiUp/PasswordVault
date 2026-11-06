import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct RelaySettingsView: View {
  @ObservedObject var relay: VaultRelay
  var t: (String, String) -> String = { zh, _ in zh }
  @State private var endpoint = ""
  @State private var peerInput = ""
  @State private var peerRole = "editor"
  @State private var familyName = ""
  @State private var confirmPersonalSync = false
  private var personalInvitation: Bool {
    guard let value = try? JSONSerialization.jsonObject(with: Data(peerInput.utf8)) as? [String:Any] else { return false }
    return value["personal"] as? Bool == true
  }
  @State private var pairInput = ""
  @State private var importing = false
  @State private var batchIDs: [String] = []
  @State private var batchChoice = "local"
  @State private var confirmingBatch = false
  #if os(iOS)
  @State private var scanning = false
  #endif
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      #if os(iOS)
      Text(t("中继同步", "Relay sync")).font(.title2)
      #endif
      if let failure = relay.failure { Text(localizedMessage(failure)).foregroundStyle(.red) }
      DisclosureGroup(t("对等密码库（无需 Mac 在线）", "Peer library (Mac can be offline)")) {
        VStack(alignment: .leading, spacing: 10) {
          Text(t("显式升级会保留旧同步日志，并使用独立设备身份。先让所有设备升级到支持对等协议的版本。", "Explicit enrollment preserves the legacy journal and uses independent device identities. Update all peers to a version supporting this protocol first."))
            .font(.caption).foregroundStyle(.secondary)
          if !relay.peerLibraries.isEmpty {
            Picker(t("当前资料库", "Current library"), selection: Binding(get: { relay.activePeerLibrary }, set: { id in Task { await relay.switchPeerLibrary(id) } })) {
              Text(t("个人资料库", "Personal library")).tag("")
              ForEach(relay.peerLibraries.filter { $0.object["personal"]?.bool != true }, id: \.self) { library in
                Text(library.object["name"]?.string ?? library.object["id"]?.string ?? "").tag(library.object["id"]?.string ?? "")
              }
            }
          }
          TextField(t("家庭库名称", "Family library name"), text: $familyName)
          Button(t("创建独立家庭库", "Create independent family library")) { Task { await relay.createPeerLibrary(personal: false, name: familyName) } }.disabled(familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || relay.config.group.isEmpty)
          Text(t("加入范围由邀请绑定；家庭库不会合并本机个人资料。", "The invitation binds its scope; family libraries never merge local personal records.")).font(.caption)
          if personalInvitation {
            Toggle(t("我确认：本机全部个人资料将同步给已授权设备", "I confirm: all local personal records will sync to authorized devices"), isOn: $confirmPersonalSync)
          }
          if relay.config.peerLibrary == nil {
            Button(t("创建并迁移为对等库", "Create peer library and migrate")) { Task { await relay.createPeerLibrary() } }.disabled(relay.config.group.isEmpty)
          } else {
            Text(relay.config.peerLibrary ?? "").font(.caption).textSelection(.enabled)
            Button(t("恢复为新共享库（重新邀请成员）", "Re-establish as a new shared library")) { Task { await relay.rekeyPeerLibrary() } }.disabled(relay.config.group.isEmpty || relay.peerLibraryRole != "admin" || (relay.summary["frozen"]?.bool != true && relay.summary["device"]?.string == relay.config.device))
            Text(t("重建会替换本机同步身份；其他设备的旧库不变，需要重新邀请。", "Re-establishment replaces this local sync identity; other devices keep their old library and need new invitations.")).font(.caption).foregroundStyle(.secondary)
            if relay.config.peerExpectedLibrary != nil {
              Text(t("等待管理员核验身份回执并授权", "Waiting for the administrator to verify and authorize this identity"))
              Button(t("取消加入，保留本机资料", "Cancel enrollment; keep local records")) { confirmPersonalSync = false; Task { await relay.cancelPeerJoin() } }
            }
            if relay.summary["frozen"]?.bool == true { Text(t("权限变更冲突，已停止同步。请从可信设备重新建立库。", "Conflicting permission changes have stopped synchronization. Re-enroll from a trusted device." )).foregroundStyle(.red) }
          }
          RelayPasteInput(text: $peerInput, placeholder: t("粘贴对等库邀请或对方身份回执", "Paste a peer-library invitation or identity request")).disabled(relay.config.peerExpectedLibrary != nil).onChange(of: peerInput) { _ in confirmPersonalSync = false }
          if relay.config.peerExpectedLibrary == nil {
            Button(t("确认邀请来源并加入", "Verify invitation source and join")) { Task { await relay.preparePeerJoin(peerInput, confirmPersonal: confirmPersonalSync) } }.disabled(peerInput.isEmpty || relay.config.group.isEmpty || (personalInvitation && !confirmPersonalSync))
          }
          if relay.config.peerLibrary != nil && relay.config.peerExpectedLibrary == nil {
            Picker(t("授权角色", "Library role"), selection: $peerRole) {
              Text(t("可编辑", "Editor")).tag("editor")
              Text(t("只读", "Reader")).tag("reader")
              Text(t("管理员", "Administrator")).tag("admin")
            }.disabled(!relay.canManagePeerLibrary)
            Button(t("已核对对方身份，授权", "Identity verified, authorize")) { Task { await relay.authorizePeerRequest(peerInput, role: peerRole) } }.disabled(peerInput.isEmpty || !relay.canManagePeerLibrary)
          }
          if !relay.pairingText.isEmpty, relay.config.peerLibrary != nil {
            Text(t("公开邀请 / 身份回执（不含密码库内容）", "Public invitation / identity request (no vault contents)"))
            Text(relay.pairingText).font(.caption2).textSelection(.enabled)
          }
          if relay.config.peerLibrary != nil {
            ForEach(Array((relay.summary["conflicts"]?.object ?? [:]).keys).sorted(), id: \.self) { key in
              VStack(alignment: .leading) {
                Text(t("并发修改：", "Concurrent changes: ") + key).bold()
                ForEach(relay.summary["conflicts"]?.object[key]?.array ?? [], id: \.self) { operation in
                  let value = operation.object["value"] ?? .null
                  Button((value.object["title"]?.string ?? t("删除 / 空值", "Delete / empty value")) + " — " + (operation.object["author"]?.string ?? "")) {
                    Task { await relay.resolvePeer(key: key, value: value) }
                  }.disabled(!relay.canWritePeerLibrary)
                }
              }
            }
          }
        }.padding(.vertical, 8)
      }

      if relay.hasManagedGroup && relay.config.peers.isEmpty {
        Text(localizedMessage(relay.status)).accessibilityIdentifier("relay-status")
      }
      if relay.config.peers.isEmpty {
        Label(t("连接你的设备", "Connect your devices"), systemImage: "laptopcomputer.and.iphone").font(.title3)
        Text(t("先创建或加入设备组，再授权密码库同步。资料在设备间加密传输。", "Create or join a device group, then authorize vault synchronization. Data travels encrypted between devices."))
          .foregroundStyle(.secondary)
      } else {
        Text(localizedMessage(relay.status)).accessibilityIdentifier("relay-status")
        if let last = relay.lastSuccess { Text(t("最近接收：", "Last received: ") + last.formatted()).font(.caption) }
        if relay.config.peerLibrary == nil { Text(t("待提交：", "Pending: ") + String(Int(relay.summary["pending"]?.number ?? 0))) }
        else { Text(t("本地已保存；中继投递不代表所有设备已应用", "Saved locally; relay delivery does not mean every device has applied it")).font(.caption) }
        HStack {
          Button(t("立即同步", "Sync now")) { relay.syncNow() }.disabled(relay.groupInvalid)
          Button(relay.config.paused ? t("恢复", "Resume") : t("暂停", "Pause")) { Task { await relay.setPaused(!relay.config.paused) } }.disabled(relay.groupInvalid)
        }
      }
      if relay.config.role == "mobile", let count = relay.summary["conflictCount"]?.number, count > 0 {
        Label(t("有 \(Int(count)) 项合并冲突，请到电脑端处理。打开 Mac 设置 → 中继同步，处理后这里会自动更新。", "\(Int(count)) merge conflicts need attention on your computer. Open Mac Settings → Relay sync; this status updates after resolution."), systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).accessibilityIdentifier("relay-conflict-reminder")
      }
      Divider()
      if relay.credentialAccessBlocked {
        Text(t("中继凭据由本机主密码保护。首次迁移旧版钥匙串时可能需要一次授权；完成后不再使用钥匙串。", "Relay credentials are protected by the local master password. Legacy Keychain migration may need one authorization; subsequent access uses the encrypted local file."))
        Button(t("迁移或重试读取中继凭据…", "Migrate or retry relay credentials…")) { Task { await relay.restoreCredentialAccess() } }
      } else if relay.credentialsReady {
      RelayGroupView(relay: relay, t: t)
      if relay.isLegacyGroup || (!relay.hasManagedGroup && !relay.joiningGroup && !relay.creatingGroup) {
        DisclosureGroup(t("兼容旧版手动接入", "Legacy manual access")) {
          Text(t("仅用于已有管理员配置；新接入请优先使用设备组。", "For existing manually provisioned access.")).font(.caption)
          Text("Group: \(relay.config.group)\nDevice: \(relay.config.device)\nPublic key: \(relay.publicKey)")
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          TextField("wss://host/relay/v1/ws", text: $endpoint).textFieldStyle(.roundedBorder).autocorrectionDisabled()
          Button(t("导入设备凭据 JSON", "Import credential JSON")) { importing = true }
        }
      }
      Divider()
      if relay.isLegacyGroup || (relay.hasManagedGroup && !relay.groupInvalid) {
      if relay.hasManagedGroup {
        Text(t("在“我的设备”中开启“查看并同步修改”。两端解锁后自动完成授权；关闭不会删除设备已下载的资料。", "Enable View and sync changes in My devices. Both vaults must be unlocked. Turning it off does not erase downloaded data.")).font(.caption).foregroundStyle(.secondary)
      }
      DisclosureGroup(t("兼容旧版密码库配对", "Legacy vault pairing")) {
      if relay.config.role == "hub" {
        Button(t("生成五分钟配对码", "Create 5-minute invitation")) { Task { await relay.invite() } }
      } else {
        Text(t("扫描 Mac 邀请后，将手机回执交给 Mac；核对两端校验码，再在 Mac 确认。", "Read the Mac invitation, return the reply, compare the codes and authorize on Mac."))
          .font(.caption).foregroundStyle(.secondary)
        #if os(iOS)
        Button(t("扫描 Mac 配对码", "Scan Mac invitation")) { scanning = true }
        #endif
      }
      if !relay.pairingText.isEmpty {
        RelayQRCode(text: relay.pairingText)
        DisclosureGroup(t("查看配对内容（可复制）", "Pairing text")) {
          Text(relay.pairingText).font(.caption2).textSelection(.enabled)
        }
      }
      RelayPasteInput(text: $pairInput, placeholder: t("粘贴配对邀请或手机回执", "Paste the vault invitation or phone reply"))
      let preview = relay.previewCode(pairInput)
      if !preview.isEmpty { Text(t("核对手机校验码：", "Verify phone code: ") + preview).bold() }
      if !relay.verificationCode.isEmpty { Text(t("校验码：", "Verification: ") + relay.verificationCode).bold() }
      Button(relay.config.role == "hub" ? t("校验码一致，授权设备", "Codes match, authorize") : t("读取邀请", "Read invitation")) {
        Task { await relay.pair(pairInput); pairInput = "" }
      }.disabled(pairInput.isEmpty || (relay.config.role == "hub" && preview.isEmpty))
      Divider()
      ForEach(relay.config.peers.keys.sorted(), id: \.self) { peer in
        HStack { Text(peer).font(.caption); Spacer(); Button(t("解除绑定", "Unpair"), role: .destructive) { Task { await relay.revoke(peer) } } }
      }
      }
      }
      }
      let conflicts = relay.summary["conflicts"]?.object ?? [:]
      if relay.config.role == "hub" && !conflicts.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(t("待处理冲突：", "Conflicts to resolve: ") + String(conflicts.count)).font(.headline)
          HStack {
            Button(t("全部采用手机端", "Use mobile for all")) {
              batchIDs = conflicts.keys.sorted(); batchChoice = "remote"; confirmingBatch = true
            }
            Button(t("全部采用 Mac 端", "Use Mac for all")) {
              batchIDs = conflicts.keys.sorted(); batchChoice = "local"; confirmingBatch = true
            }
          }
          if relay.resolvingConflicts { ProgressView(t("正在处理冲突…", "Resolving conflicts…")) }
        }
      }
      ForEach(conflicts.keys.sorted(), id: \.self) { id in
        RelayConflictRow(id: id, conflict: conflicts[id] ?? .null, relay: relay, t: t)
      }
      Text(t("Mac 解锁后处理同步。中继暂存不代表已写入 Mac；手机本地编辑会保留到主库确认。", "Mac processes sync while unlocked. Local mobile changes remain pending until Mac confirms them."))
        .font(.caption).foregroundStyle(.secondary)
    }
    .disabled(relay.groupBusy || relay.resolvingConflicts)
    .alert(batchChoice == "remote" ? t("全部采用手机端？", "Use mobile for all?") : t("全部采用 Mac 端？", "Use Mac for all?"), isPresented: $confirmingBatch) {
      Button(t("取消", "Cancel"), role: .cancel) { batchIDs = [] }
      Button(t("确认处理", "Resolve conflicts"), role: .destructive) {
        let ids = batchIDs, choice = batchChoice
        Task { await relay.resolveConflicts(ids, choice: choice) }
      }
    } message: {
      Text(t("将处理当前选中的 \(batchIDs.count) 项冲突，统一采用所选端的版本（包括删除操作）。另一端的冲突版本将被替换；之后新增的冲突不会自动处理。", "Resolve the selected \(batchIDs.count) conflicts using the chosen side, including deletions. Conflicting versions on the other side will be replaced. New conflicts are excluded."))
    }
    .onAppear { endpoint = relay.config.endpoint }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
      guard case .success(let url) = result else { return }
      Task {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bytes = try? Data(contentsOf: url), bytes.count <= 16384,
              let text = String(data: bytes, encoding: .utf8) else { return }
        await relay.importCredential(text, endpoint: endpoint)
      }
    }
    #if os(iOS)
    .sheet(isPresented: $scanning) { MobileQRImport(apply: { _ in }, payloadHandler: { text in pairInput = text; scanning = false }) }
    #endif
  }
  private func localizedMessage(_ text: String) -> String {
    let parts = text.components(separatedBy: " / ")
    return parts.count == 2 ? t(parts[0], parts[1]) : text
  }

}

struct RelayQRCode: View {
  let text: String
  var body: some View {
    if let image = qr(text) {
      Image(decorative: image, scale: 1).interpolation(.none).resizable().frame(width: 220, height: 220)
        .padding(8).background(.white).accessibilityLabel("Pairing QR code")
    }
  }
  private func qr(_ text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
    guard let output = filter.outputImage else { return nil }
    return CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), from: output.extent.applying(CGAffineTransform(scaleX: 6, y: 6)))
  }
}

private struct RelayConflictRow: View {
  let id: String
  let conflict: JSONValue
  @ObservedObject var relay: VaultRelay
  var t: (String, String) -> String = { zh, _ in zh }
  @State private var reveal = false
  private func formatted(_ value: JSONValue) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(t("冲突：", "Conflict: ") + (conflict.object["change"]?.object["key"]?.string ?? id)).font(.headline)
      Text("Mac: \(conflict.object["local"]?.object["title"]?.string ?? t("删除或分类", "Deletion or categories"))")
      Text("Mobile: \(conflict.object["change"]?.object["value"]?.object["title"]?.string ?? t("删除或分类", "Deletion or categories"))")
      Toggle(t("显示双方完整内容（含敏感字段）", "Reveal full versions"), isOn: $reveal)
      if reveal {
        Text("Mac").bold()
        Text(formatted(conflict.object["local"] ?? .null)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        Text("Mobile").bold()
        Text(formatted(conflict.object["change"]?.object["value"] ?? .null)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      }
      HStack {
        Button(t("保留 Mac", "Keep Mac")) { Task { await relay.resolve(id, choice: "local") } }
        Button(t("采用手机", "Use mobile")) { Task { await relay.resolve(id, choice: "remote") } }
        Button(t("保留两份", "Keep both")) { Task { await relay.resolve(id, choice: "both") } }
      }
    }
  }
}

struct RelayPasteInput: View {
  @Binding var text: String
  let placeholder: String
  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty { Text(placeholder).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 12).allowsHitTesting(false) }
      TextEditor(text: $text).scrollContentBackground(.hidden).padding(6)
        .accessibilityLabel(placeholder)
    }
    .frame(height: 88)
    .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
  }
}
