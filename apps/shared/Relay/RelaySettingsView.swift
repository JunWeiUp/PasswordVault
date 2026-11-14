import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct RelaySettingsView: View {
  @ObservedObject var relay: VaultRelay
  var t: (String, String) -> String = { zh, _ in zh }
  @State private var peerInput = ""
  @State private var peerRole = "editor"
  @State private var familyName = ""
  @State private var confirmPersonalSync = false
  private var personalInvitation: Bool {
    guard let value = try? JSONSerialization.jsonObject(with: Data(peerInput.utf8)) as? [String:Any] else { return false }
    return value["personal"] as? Bool == true
  }
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

      if relay.meshPeers != nil {
        Text(localizedMessage(relay.status)).accessibilityIdentifier("relay-status")
        if let last = relay.lastSuccess { Text(t("最近同步：", "Last sync: ") + last.formatted()).font(.caption) }
        Text(t("组内设备自动双向同步。多台设备同时修改同一条时以较新的修改为准，较旧版本可在条目历史中找回。", "Devices in the group sync both ways automatically. The newer edit wins; older versions stay in entry history."))
          .font(.caption).foregroundStyle(.secondary)
        Button(t("立即同步", "Sync now")) { relay.syncNow() }.disabled(relay.groupInvalid)
      } else if !relay.hasManagedGroup {
        Label(t("连接你的设备", "Connect your devices"), systemImage: "laptopcomputer.and.iphone").font(.title3)
        Text(t("创建设备组，或扫描已入组设备上的邀请二维码。组内设备自动双向同步，资料在设备间加密传输。", "Create a device group or scan an invitation from a device already in it. Devices in the group sync both ways automatically with end-to-end encryption."))
          .foregroundStyle(.secondary)
      } else {
        Text(localizedMessage(relay.status)).accessibilityIdentifier("relay-status")
      }
      Divider()
      if relay.credentialAccessBlocked {
        Text(t("中继凭据由本机主密码保护。首次迁移旧版钥匙串时可能需要一次授权；完成后不再使用钥匙串。", "Relay credentials are protected by the local master password. Legacy Keychain migration may need one authorization; subsequent access uses the encrypted local file."))
        Button(t("迁移或重试读取中继凭据…", "Migrate or retry relay credentials…")) { Task { await relay.restoreCredentialAccess() } }
      } else if relay.credentialsReady {
        RelayGroupView(relay: relay, t: t)
      }
    }
    .disabled(relay.groupBusy)
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
