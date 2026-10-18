import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct RelaySettingsView: View {
  @ObservedObject var relay: VaultRelay
  @State private var endpoint = ""
  @State private var pairInput = ""
  @State private var importing = false
  #if os(iOS)
  @State private var scanning = false
  #endif
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("中继同步 / Relay sync").font(.title2)
      Text(relay.status).accessibilityIdentifier("relay-status")
      if let failure = relay.failure { Text(failure).foregroundStyle(.red) }
      if let last = relay.lastSuccess { Text("最近接收 / Last received: \(last.formatted())").font(.caption) }
      Text("待提交 / Pending: \(Int(relay.summary["pending"]?.number ?? 0))")
      HStack {
        Button("立即同步 / Sync now") { relay.syncNow() }
        Button(relay.config.paused ? "恢复 / Resume" : "暂停 / Pause") { Task { await relay.setPaused(!relay.config.paused) } }
      }
      Divider()
      Text("1. 登记设备 / Register device").font(.headline)
      Text("将下列公钥交给中继管理员登记 passwordvault 设备。手机使用 Mac 相同的设备组。")
        .font(.caption).foregroundStyle(.secondary)
      Text("Group: \(relay.config.group)\nDevice: \(relay.config.device)\nPublic key: \(relay.publicKey)")
        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      TextField("wss://host/relay/v1/ws", text: $endpoint)
        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
      Button("导入设备凭据 JSON / Import credential JSON") { importing = true }
      Divider()
      Text("2. 配对 / Pair").font(.headline)
      if relay.config.role == "hub" {
        Button("生成五分钟配对码 / Create 5-minute invitation") { Task { await relay.invite() } }
      } else {
        Text("扫描 Mac 邀请后，将手机回执交给 Mac；核对两端校验码，再在 Mac 确认。")
          .font(.caption).foregroundStyle(.secondary)
        #if os(iOS)
        Button("扫描 Mac 配对码 / Scan Mac invitation") { scanning = true }
        #endif
      }
      if !relay.pairingText.isEmpty {
        if let image = qr(relay.pairingText) {
          Image(decorative: image, scale: 1).interpolation(.none).resizable().frame(width: 220, height: 220)
            .padding(8).background(.white).accessibilityLabel("Pairing QR code")
        }
        Text(relay.pairingText).font(.caption2).textSelection(.enabled)
      }
      TextEditor(text: $pairInput).frame(minHeight: 72, maxHeight: 110)
        .accessibilityLabel("配对内容 / Pairing payload")
      let preview = relay.previewCode(pairInput)
      if !preview.isEmpty { Text("核对手机校验码 / Verify phone code: \(preview)").bold() }
      if !relay.verificationCode.isEmpty { Text("校验码 / Verification: \(relay.verificationCode)").bold() }
      Button(relay.config.role == "hub" ? "校验码一致，授权设备 / Codes match, authorize" : "读取邀请 / Read invitation") {
        Task { await relay.pair(pairInput); pairInput = "" }
      }.disabled(pairInput.isEmpty || (relay.config.role == "hub" && preview.isEmpty))
      Divider()
      ForEach(relay.config.peers.keys.sorted(), id: \.self) { peer in
        HStack { Text(peer).font(.caption); Spacer(); Button("解除绑定 / Unpair", role: .destructive) { Task { await relay.revoke(peer) } } }
      }
      let conflicts = relay.summary["conflicts"]?.object ?? [:]
      ForEach(conflicts.keys.sorted(), id: \.self) { id in
        RelayConflictRow(id: id, conflict: conflicts[id] ?? .null, relay: relay)
      }
      Text("Mac 解锁后处理同步。中继暂存不代表已写入 Mac；手机本地编辑会保留到主库确认。")
        .font(.caption).foregroundStyle(.secondary)
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
  @State private var reveal = false
  private func formatted(_ value: JSONValue) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("冲突 / Conflict: \(conflict.object["change"]?.object["key"]?.string ?? id)").font(.headline)
      Text("Mac: \(conflict.object["local"]?.object["title"]?.string ?? "删除或分类 / Deletion or categories")")
      Text("Mobile: \(conflict.object["change"]?.object["value"]?.object["title"]?.string ?? "删除或分类 / Deletion or categories")")
      Toggle("显示双方完整内容（含敏感字段）/ Reveal full versions", isOn: $reveal)
      if reveal {
        Text("Mac").bold()
        Text(formatted(conflict.object["local"] ?? .null)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        Text("Mobile").bold()
        Text(formatted(conflict.object["change"]?.object["value"] ?? .null)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      }
      HStack {
        Button("保留 Mac / Keep Mac") { Task { await relay.resolve(id, choice: "local") } }
        Button("采用手机 / Use mobile") { Task { await relay.resolve(id, choice: "remote") } }
        Button("保留两份 / Keep both") { Task { await relay.resolve(id, choice: "both") } }
      }
    }
  }
}
