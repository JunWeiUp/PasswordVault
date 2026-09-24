import CoreImage.CIFilterBuiltins
import SwiftUI

struct SharingView: View {
  @EnvironmentObject private var store: AppStore
  @ObservedObject var service: LocalSyncService
  @State private var publicKey = ""
  @State private var name = ""
  @State private var selectedVault = ""
  @State private var memberKey = ""
  @State private var memberName = ""
  @State private var role = "viewer"
  @State private var invitation = ""
  @State private var joinInput = ""
  @State private var busy = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DetailToolbar(title: store.t("共享资料库", "Shared vaults"))
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text(store.t("共享资料库", "Shared vaults")).font(.system(size: 30, weight: .semibold))
          Text(
            store.t(
              "仅向你确认的成员共享。新协议需要双方使用原生 V2 客户端。",
              "Share only with members you approve. Both devices need a V2 client.")
          ).foregroundStyle(.secondary)
          DisclosureGroup(store.t("我的共享公钥", "My sharing public key")) {
            Text(publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            HStack {
              QRCodeImage(value: publicKey).frame(width: 140, height: 140)
              Button(store.t("复制公钥", "Copy public key")) { store.copy(publicKey) }
            }.padding(.vertical, 12)
          }
          Divider()
          HStack {
            TextField(store.t("新资料库名称", "New shared vault name"), text: $name)
            Button(store.t("创建", "Create")) { Task { await create() } }.buttonStyle(
              VaultButtonStyle(.primary)
            ).tint(Palette.blue).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
          }
          Picker(store.t("资料库", "Vault"), selection: $selectedVault) {
            Text(store.t("选择资料库", "Select vault")).tag("")
            ForEach(store.sharedVaults, id: \.self) { vault in
              Text(vault.object["name"]?.string ?? "").tag(vault.object["id"]?.string ?? "")
            }
          }
          if !selectedVault.isEmpty {
            Text(store.t("添加成员", "Add member")).font(.headline)
            TextField(store.t("对方的共享公钥", "Recipient sharing public key"), text: $memberKey)
            HStack {
              TextField(store.t("成员备注", "Member label"), text: $memberName)
              Picker(store.t("权限", "Role"), selection: $role) {
                Text(store.t("只读", "Viewer")).tag("viewer")
                Text(store.t("可编辑", "Editor")).tag("editor")
              }.frame(width: 180)
            }
            Button(store.t("授权此成员", "Authorize member")) { Task { await addMember() } }.disabled(
              memberKey.isEmpty)
            ForEach(
              store.sharedMembers.filter { $0.object["vaultId"]?.string == selectedVault },
              id: \.self
            ) { member in
              HStack {
                Text(
                  member.object["name"]?.string.isEmpty == false
                    ? member.object["name"]!.string
                    : String((member.object["userPublicKey"]?.string ?? "").prefix(18)) + "…")
                Spacer()
                Text(member.object["role"]?.string ?? "").foregroundStyle(.secondary)
                if member.object["role"]?.string != "owner" {
                  Button(store.t("撤销", "Revoke"), role: .destructive) {
                    Task {
                      do {
                        _ = try await store.perform([
                          "op": .string("remove-member"), "vaultId": .string(selectedVault),
                          "publicKey": member.object["userPublicKey"] ?? .null,
                        ])
                        await store.refresh()
                      } catch { store.report(error) }
                    }
                  }
                }
              }.font(.caption)
            }
          }
          Divider()
          SettingsRow(
            title: store.t("局域网共享", "Local network sharing"),
            subtitle: store.t("锁定资料库时自动停止。", "Stops automatically when the vault locks.")
          ) {
            Toggle(
              "Sharing",
              isOn: Binding(
                get: { service.running }, set: { $0 ? service.start() : service.stop() })
            ).labelsHidden().toggleStyle(.switch)
          }
          if service.running {
            Text(service.endpoint).font(.system(.caption, design: .monospaced)).textSelection(
              .enabled)
            if !selectedVault.isEmpty {
              Button(store.t("生成邀请链接", "Create invitation link"), action: makeInvitation)
              if !invitation.isEmpty {
                HStack {
                  QRCodeImage(value: invitation).frame(width: 150, height: 150)
                  Button(store.t("复制邀请", "Copy invitation")) { store.copy(invitation) }
                }
              }
            }
            Text(store.t("附近设备：\(service.peers.count)", "Nearby devices: \(service.peers.count)"))
              .font(.caption).foregroundStyle(.secondary)
          }
          Text(store.t("接收邀请与同步", "Accept invitation and sync")).font(.headline)
          TextField("passwordvault://join?…", text: $joinInput)
          Button(store.t("连接并同步", "Connect and sync")) { Task { await join() } }.disabled(
            joinInput.isEmpty)
          if busy { ProgressView().controlSize(.small) }
          Text(
            store.t(
              "先让资料库所有者添加你的公钥，再通过当面或可信渠道核对邀请。",
              "Ask the owner to authorize your public key first. Verify the invitation in person or through a trusted channel."
            )
          ).font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder).padding(36).frame(maxWidth: 900, alignment: .leading)
          .disabled(busy)
      }
    }.task {
      do {
        publicKey =
          try await store.perform(["op": .string("identity")]).object["publicKey"]?.string ?? ""
        await store.refresh()
      } catch { store.report(error) }
    }
  }

  private func create() async {
    do {
      let value = try await store.perform([
        "op": .string("create-shared"), "name": .string(name),
        "time": .string(ISO8601DateFormatter().string(from: Date())),
      ])
      await store.refresh()
      selectedVault = value.object["id"]?.string ?? ""
      name = ""
    } catch { store.report(error) }
  }
  private func addMember() async {
    do {
      _ = try await store.perform([
        "op": .string("add-member"), "vaultId": .string(selectedVault),
        "publicKey": .string(memberKey.trimmingCharacters(in: .whitespacesAndNewlines)),
        "role": .string(role), "name": .string(memberName),
      ])
      await store.refresh()
      memberKey = ""
      memberName = ""
      store.showToast(store.t("成员已授权", "Member authorized"))
    } catch { store.report(error) }
  }
  private func makeInvitation() {
    var url = URLComponents()
    url.scheme = "passwordvault"
    url.host = "join"
    url.queryItems = [
      URLQueryItem(name: "version", value: "2"),
      URLQueryItem(name: "endpoint", value: service.endpoint),
      URLQueryItem(name: "key", value: publicKey),
      URLQueryItem(name: "vault", value: selectedVault),
    ]
    invitation = url.string ?? ""
  }
  private func join() async {
    busy = true
    defer { busy = false }
    do {
      guard let url = URLComponents(string: joinInput), url.scheme == "passwordvault",
        url.host == "join"
      else { throw VaultError.InvalidData }
      let pairs = url.queryItems ?? []
      guard Set(pairs.map(\.name)).count == pairs.count else { throw VaultError.InvalidData }
      let query = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
      guard query["version"] == "2", let endpoint = query["endpoint"], let peer = query["key"],
        let vault = query["vault"]
      else { throw VaultError.InvalidData }
      let request = try await store.perform([
        "op": .string("sync-request"), "peerKey": .string(peer), "vaultId": .string(vault),
      ])
      let response = try await LocalSyncService.exchange(endpoint: endpoint, packet: request)
      _ = try await store.perform([
        "op": .string("sync-apply"), "packet": response, "peerKey": .string(peer),
        "vaultId": .string(vault),
      ])
      await store.refresh()
      selectedVault = vault
      store.showToast(store.t("同步完成", "Sync complete"))
    } catch { store.report(error) }
  }
}

struct QRCodeImage: View {
  let value: String
  private var image: NSImage? {
    guard !value.isEmpty else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    guard let output = filter.outputImage,
      let cg = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
  var body: some View {
    if let image {
      Image(nsImage: image).resizable().interpolation(.none).scaledToFit().padding(8).background(
        .white)
    }
  }
}
