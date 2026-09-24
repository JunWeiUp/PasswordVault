import CoreImage.CIFilterBuiltins
import SwiftUI

struct MobileSharingView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @ObservedObject var service: MobileLocalSyncService
  @State private var publicKey = ""
  @State private var name = ""
  @State private var selected = ""
  @State private var memberKey = ""
  @State private var role = "viewer"
  @State private var invitation = ""
  @State private var join = ""
  @State private var working = false
  var body: some View {
    Form {
      Section {
        Text(
          store.t(
            "双方使用原生 V2 客户端。请通过当面或可信渠道核对公钥和邀请。",
            "Both devices need a native V2 client. Verify public keys and invitations in person or through a trusted channel."
          ))
        DisclosureGroup(store.t("我的共享公钥", "My sharing public key")) {
          Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
          MobileQRCode(value: publicKey).frame(height: 160)
          Button(store.t("复制公钥", "Copy public key")) { store.copy(publicKey) }
        }
      }
      Section(store.t("共享资料库", "Shared vaults")) {
        TextField(store.t("新资料库名称", "New vault name"), text: $name)
        Button(store.t("创建资料库", "Create shared vault")) {
          run {
            let value = try await store.perform([
              "op": .string("create-shared"), "name": .string(name),
              "time": .string(ISO8601DateFormatter().string(from: Date())),
            ])
            selected = value.object["id"]?.string ?? ""
            name = ""
          }
        }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        Picker(store.t("资料库", "Vault"), selection: $selected) {
          Text(store.t("请选择", "Choose")).tag("")
          ForEach(store.sharedVaults, id: \.self) {
            Text($0.object["name"]?.string ?? "").tag($0.object["id"]?.string ?? "")
          }
        }
        if !selected.isEmpty {
          TextField(store.t("对方共享公钥", "Recipient public key"), text: $memberKey)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          Picker(store.t("权限", "Role"), selection: $role) {
            Text(store.t("只读", "Viewer")).tag("viewer")
            Text(store.t("可编辑", "Editor")).tag("editor")
          }
          Button(store.t("授权此成员", "Authorize member")) {
            run {
              _ = try await store.perform([
                "op": .string("add-member"), "vaultId": .string(selected),
                "publicKey": .string(memberKey.trimmingCharacters(in: .whitespacesAndNewlines)),
                "role": .string(role), "name": .string(""),
              ])
              memberKey = ""
            }
          }.disabled(memberKey.isEmpty)
          ForEach(
            store.sharedMembers.filter { $0.object["vaultId"]?.string == selected }, id: \.self
          ) { member in
            VStack(alignment: .leading) {
              Text(String((member.object["userPublicKey"]?.string ?? "").prefix(18)) + "…").font(
                .caption.monospaced())
              Text(member.object["role"]?.string ?? "").font(.caption)
              if member.object["role"]?.string != "owner" {
                Button(store.t("撤销授权", "Revoke access"), role: .destructive) {
                  run {
                    _ = try await store.perform([
                      "op": .string("remove-member"), "vaultId": .string(selected),
                      "publicKey": member.object["userPublicKey"] ?? .null,
                    ])
                  }
                }
              }
            }
          }
        }
      }
      Section(store.t("局域网同步", "Local network sync")) {
        Toggle(
          store.t("允许已授权成员连接", "Allow authorized members to connect"),
          isOn: Binding(get: { service.running }, set: { $0 ? service.start() : service.stop() }))
        if service.running {
          Text(service.endpoint).font(.caption.monospaced())
          Button(store.t("生成邀请", "Create invitation")) {
            var url = URLComponents()
            url.scheme = "passwordvault"
            url.host = "join"
            url.queryItems = [
              .init(name: "version", value: "2"), .init(name: "endpoint", value: service.endpoint),
              .init(name: "key", value: publicKey), .init(name: "vault", value: selected),
            ]
            invitation = url.string ?? ""
          }.disabled(selected.isEmpty)
          if !invitation.isEmpty {
            MobileQRCode(value: invitation).frame(height: 180)
            Button(store.t("复制邀请", "Copy invitation")) { store.copy(invitation) }
          }
        }
        TextField("passwordvault://join?…", text: $join).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button(store.t("连接并同步", "Connect and sync")) {
          run {
            guard let url = URLComponents(string: join), url.scheme == "passwordvault",
              url.host == "join"
            else { throw VaultError.InvalidData }
            let pairs = url.queryItems ?? []
            guard Set(pairs.map(\.name)).count == pairs.count else { throw VaultError.InvalidData }
            let values = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
            guard values["version"] == "2", let endpoint = values["endpoint"],
              let key = values["key"], let vault = values["vault"]
            else { throw VaultError.InvalidData }
            let packet = try await store.perform([
              "op": .string("sync-request"), "peerKey": .string(key), "vaultId": .string(vault),
            ])
            let response = try await MobileLocalSyncService.exchange(
              endpoint: endpoint, packet: packet)
            _ = try await store.perform([
              "op": .string("sync-apply"), "packet": response, "peerKey": .string(key),
              "vaultId": .string(vault),
            ])
            selected = vault
            store.notice = store.t("同步完成", "Sync complete")
          }
        }.disabled(join.isEmpty)
        Text(store.t("锁定或切到后台会停止共享。", "Sharing stops when locked or backgrounded.")).font(.caption)
      }
      if working { ProgressView() }
    }.disabled(working).navigationTitle(store.t("共享资料库", "Shared vaults"))
      .task {
        run {
          publicKey =
            try await store.perform(["op": .string("identity")]).object["publicKey"]?.string ?? ""
        }
      }
  }
  private func run(_ work: @escaping () async throws -> Void) {
    guard !working else { return }
    working = true
    Task {
      defer { working = false }
      do {
        try await work()
        try await store.refresh()
      } catch { store.report(error) }
    }
  }
}
struct MobileQRCode: View {
  let value: String
  var body: some View {
    if let image {
      Image(uiImage: image).resizable().interpolation(.none).scaledToFit().padding(12).background(
        .white)
    }
  }
  private var image: UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    guard let output = filter.outputImage,
      let image = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: image)
  }
}
