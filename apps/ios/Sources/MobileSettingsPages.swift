import AuthenticationServices
import SwiftUI

/// Settings › AutoFill & passkeys: whether PasswordVault is the enabled credential provider,
/// and a way to the system setting. iOS decides; the app can only report and link.
struct MobileAutofillSettings: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var enabled: Bool?
  @AppStorage(CredentialSuggestions.defaultsKey) private var suggestions = true

  var body: some View {
    Form {
      Section {
        LabeledContent(store.t("密码自动填充", "Password AutoFill")) {
          Text(enabled == nil ? store.t("正在检查…", "Checking…") : enabled! ? store.t("已启用", "On") : store.t("未启用", "Off"))
            .foregroundStyle(enabled == true ? .green : .secondary)
        }
        Button(store.t("打开系统设置", "Open system settings")) { openSettings() }
        Toggle(store.t("在键盘上方显示账号建议", "Suggest accounts above the keyboard"), isOn: $suggestions)
          .onChange(of: suggestions) { _ in Task { await store.refreshCredentialSuggestions() } }
      } footer: {
        Text(store.t(
          "在系统设置的“通用 › 自动填充与密码”中选择 PasswordVault。账号建议只向系统提供网站和用户名，不包含密码；填充前需要解锁。新账号的保存提示由系统显示。",
          "Choose PasswordVault in Settings › General › AutoFill & Passwords. Suggestions give iOS only the site and username, never the password; filling requires unlocking. iOS shows the prompt to save new accounts."))
      }
    }
    .navigationTitle(store.t("自动填充与通行密钥", "AutoFill & passkeys"))
    .task { await refresh() }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      Task { await refresh() }
    }
  }

  private func refresh() async {
    enabled = await boundedCompletion(timeout: 5, fallback: false) { done in
      ASCredentialIdentityStore.shared.getState { state in done(state.isEnabled) }
    }
  }

  private func openSettings() {
    if #available(iOS 17.0, *) {
      Task { try? await ASSettingsHelper.openCredentialProviderAppSettings() }
    } else if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
    }
  }
}

/// Settings › About. The version comes from the bundle; no production-security claim.
struct MobileAboutView: View {
  @EnvironmentObject private var store: MobileVaultStore

  private var version: String {
    let info = Bundle.main.infoDictionary
    return "\(info?["CFBundleShortVersionString"] as? String ?? "—") (\(info?["CFBundleVersion"] as? String ?? "—"))"
  }

  var body: some View {
    Form {
      Section {
        LabeledContent(store.t("版本", "Version"), value: version)
        Link(store.t("发布说明", "Release notes"), destination: URL(string: "https://github.com/JunWeiUp/PasswordVault/releases")!)
        NavigationLink(store.t("开源许可", "Open-source licenses")) { MobileLicensesView() }
      }
      Section {
        Text(store.t(
          "资料在本机加密保存；只在你主动操作（同步、备份、泄露检查）时联网。PasswordVault 尚未完成独立安全审计，请保留加密备份。",
          "Data is encrypted on this device and goes online only when you sync, back up or run a breach check. PasswordVault has not had an independent security review; keep encrypted backups."))
          .font(.footnote).foregroundStyle(.secondary)
      }
    }.navigationTitle(store.t("关于", "About"))
  }
}

struct MobileLicensesView: View {
  private var text: String {
    guard let url = Bundle.main.url(forResource: "NoteEditor-LICENSES", withExtension: "txt"),
      let value = try? String(contentsOf: url, encoding: .utf8)
    else { return "—" }
    return value
  }
  var body: some View {
    ScrollView { Text(text).font(.caption.monospaced()).textSelection(.enabled).padding() }
      .navigationTitle("Licenses")
  }
}
