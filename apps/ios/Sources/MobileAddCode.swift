import SwiftUI

/// Builds new authenticator entries from a parsed setup link or manual input. Only what the
/// core supports is offered: TOTP with SHA1, 6 digits and a period of 1–86400 seconds.
enum CodeSetup {
  static let periods = 1...86400

  /// Base32 keys are often shown in groups and lower case; the core expects neither.
  static func normalizedSecret(_ value: String) -> String {
    value.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
  }

  /// A new code entry, or nil when the key is empty or the period is out of range.
  static func item(_ fields: [String: JSONValue]) -> VaultItem? {
    let secret = normalizedSecret(fields["secret"]?.string ?? "")
    let period = fields["period"]?.number ?? 30
    guard !secret.isEmpty, period == period.rounded(), periods.contains(Int(period)) else { return nil }
    let issuer = (fields["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let account = (fields["username"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var item = VaultItem.blank(type: "totp", title: issuer.isEmpty ? account : issuer)
    item.username = account
    item.set("secret", secret)
    item.fields["period"] = .number(period)
    return item
  }

  /// Password entries whose own setup key matches this code (the link used across clients).
  static func linkedAccounts(_ code: VaultItem, in items: [VaultItem]) -> [VaultItem] {
    let secret = normalizedSecret(code.string("secret"))
    guard !secret.isEmpty else { return [] }
    return items.filter {
      $0.type == "password" && !$0.isDeleted && normalizedSecret($0.string("secret")) == secret
    }
  }
}

extension MobileVaultStore {
  /// Validates and saves a new code. Returns an error message, or nil when saved.
  func addCode(_ fields: [String: JSONValue]) async -> String? {
    guard let item = CodeSetup.item(fields) else {
      return t("请填写有效的密钥，周期为 1–86400 秒。", "Enter a valid setup key and a period of 1–86400 seconds.")
    }
    do {
      _ = try await perform([
        "op": .string("totp"), "secret": .string(item.string("secret")),
        "period": .number(item.number("period", fallback: 30)),
        "time": .number(Date().timeIntervalSince1970.rounded(.down)),
      ])
    } catch {
      return t("设置密钥无效，请检查后重试。", "Invalid setup key. Check it and retry.")
    }
    if await save(item) {
      let name = item.title.isEmpty ? t("验证码", "code") : item.title
      notice = t("已添加 \(name) 验证码", "Added \(name)")
      return nil
    }
    let message = error ?? t("保存失败，请重试。", "Could not save; retry.")
    error = nil
    return message
  }
}

/// "Add code" sheet: scan a QR code, pick an image, paste a setup link or enter the key.
struct AddCodeSheet: View {
  @EnvironmentObject private var store: MobileVaultStore
  var body: some View {
    MobileQRImport(apply: { _ in }, save: { await store.addCode($0) }, manual: true)
      .presentationDetents([.medium, .large])
  }
}

/// Manual key entry. Digits and algorithm are fixed by the core (6 digits, SHA1).
struct ManualCodeForm: View {
  @EnvironmentObject private var store: MobileVaultStore
  let save: ([String: JSONValue]) async -> String?
  var done: () -> Void
  @State private var issuer = ""
  @State private var account = ""
  @State private var secret = ""
  @State private var period = "30"
  @State private var saving = false
  @State private var message: String?
  var body: some View {
    Form {
      Section {
        TextField(store.t("发行方，例如 GitLab", "Issuer, e.g. GitLab"), text: $issuer)
          .accessibilityIdentifier("code.issuer")
        TextField(store.t("账号", "Account"), text: $account)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        TextField(store.t("密钥（Base32）", "Setup key (Base32)"), text: $secret)
          .font(.body.monospaced()).textInputAutocapitalization(.characters).autocorrectionDisabled()
          .privacySensitive().accessibilityIdentifier("code.secret")
        HStack {
          Text(store.t("周期（秒）", "Period (seconds)"))
          Spacer()
          TextField("30", text: $period).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            .frame(maxWidth: 90).accessibilityIdentifier("code.period")
        }
        LabeledContent(store.t("位数 · 算法", "Digits · algorithm"), value: store.t("6 位 · SHA1", "6 · SHA1"))
      } footer: {
        Text(store.t("当前只支持 6 位 SHA1 验证码。", "Only 6-digit SHA1 codes are supported."))
      }
      if let message { Section { Text(message).foregroundStyle(.red) } }
    }
    .navigationTitle(store.t("手动输入密钥", "Enter setup key")).navigationBarTitleDisplayMode(.inline)
    .disabled(saving)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(store.t("添加", "Add")) {
          saving = true
          message = nil
          Task {
            defer { saving = false }
            let fields: [String: JSONValue] = [
              "title": .string(issuer), "username": .string(account), "secret": .string(secret),
              "period": .number(Double(period.trimmingCharacters(in: .whitespaces)) ?? 0),
            ]
            if let failure = await save(fields) { message = failure } else { done() }
          }
        }
        .disabled(saving || CodeSetup.normalizedSecret(secret).isEmpty)
        .accessibilityIdentifier("code.add")
      }
    }
  }
}
