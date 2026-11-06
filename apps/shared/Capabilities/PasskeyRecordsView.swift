import SwiftUI

struct PasskeyRecordsView: View {
  let item: VaultItem
  let perform: ([String: JSONValue]) async throws -> JSONValue
  let refresh: () async -> Void
  let t: (String, String) -> String
  var editable = true
  @State private var selected: String?
  @State private var currentPassword = ""
  @State private var busy = false
  @State private var error = ""
  var body: some View {
    if let keys = item.fields["passkeys"]?.array, !keys.isEmpty {
      Section("Passkeys") {
        ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
          VStack(alignment: .leading, spacing: 6) {
            Text(key.object["rpId"]?.string ?? "").font(.headline)
            Text(key.object["userName"]?.string ?? "")
            Text(key.object["credentialId"]?.string ?? "").font(.caption.monospaced()).textSelection(.enabled)
            Button(t("删除通行密钥…", "Delete Passkey…"), role: .destructive) { selected = key.object["credentialId"]?.string; currentPassword = ""; error = "" }.disabled(!editable)
          }
        }
      }
      .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 && !busy { selected = nil; currentPassword = "" } })) {
        VStack(alignment: .leading, spacing: 16) {
          Text(t("删除此通行密钥？", "Delete this Passkey?")).font(.headline)
          Text(t("这会移除资料库中的凭证。请确认网站仍有其他登录方式；网站注册不会自动撤销。", "This removes the vault credential. Ensure another sign-in method exists; the website registration is not automatically revoked."))
          SecureField(t("当前主密码", "Current master password"), text: $currentPassword)
          if !error.isEmpty { Text(error).foregroundStyle(.red) }
          HStack {
            Button(t("取消", "Cancel")) { selected = nil; currentPassword = "" }.disabled(busy)
            Button(t("确认删除", "Delete"), role: .destructive) {
              Task { await removeSelected() }
            }.disabled(busy || currentPassword.isEmpty)
          }
        }.padding(24).frame(minWidth: 300, idealWidth: 420).interactiveDismissDisabled(busy)
      }
    }
  }
  @MainActor private func removeSelected() async {
    guard let selected else { return }
    busy = true
    defer { busy = false; currentPassword = "" }
    do {
      _ = try await perform(["op":.string("passkey-remove"),"itemId":.string(item.id),"credentialId":.string(selected),"currentPassword":.string(currentPassword)])
      await refresh(); self.selected = nil
    } catch {
      self.error = t("未能删除，请检查主密码后重试。", "Could not delete; verify the master password and retry.")
    }
  }

}
