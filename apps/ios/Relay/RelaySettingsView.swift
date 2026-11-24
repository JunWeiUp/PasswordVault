import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct RelaySettingsView: View {
  @ObservedObject var relay: VaultRelay
  var t: (String, String) -> String = { zh, _ in zh }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      #if os(iOS)
      Text(t("中继同步", "Relay sync")).font(.title2)
      #endif
      if let failure = relay.failure { Text(localizedMessage(failure)).foregroundStyle(.red) }
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
