import SwiftUI

struct UnlockView: View {
  @EnvironmentObject private var store: AppStore
  @State private var password = ""
  @State private var confirmation = ""
  @State private var showPassword = false
  @FocusState private var focused: Bool

  var body: some View {
    VStack {
      HStack {
        Brand(size: 25).padding(.leading, 90)
        Spacer()
      }.frame(height: 42)
      Divider()
      Spacer()
      VStack(spacing: 22) {
        Brand(size: 66, showName: false)
        Text(
          store.exists
            ? store.t("PasswordVault 已锁定", "PasswordVault is locked")
            : store.t("创建你的加密资料库", "Create your encrypted vault")
        )
        .font(.system(size: 28, weight: .semibold))
        Text(
          store.exists
            ? store.t("解锁后查看你的笔记和密码", "Unlock to access your notes and passwords")
            : store.t(
              "设置主密码，开始保存重要信息", "Choose a master password to protect your important information")
        )
        .foregroundStyle(.secondary)
        if !store.ready || store.busy { ProgressView().controlSize(.small).frame(height: 24) }
        if store.exists && store.biometricEnabled && !showPassword {
          Image(systemName: "touchid").font(.system(size: 48, weight: .light)).foregroundStyle(
            Palette.blue
          ).padding(.top, 12)
          Button(store.t("使用 Touch ID 解锁", "Unlock with Touch ID")) {
            Task { await store.unlockWithBiometrics() }
          }
          .buttonStyle(VaultButtonStyle(.primary)).tint(Palette.blue).controlSize(.large).frame(
            maxWidth: .infinity)
          Button(store.t("使用主密码", "Use master password")) {
            showPassword = true
            focused = true
          }.buttonStyle(VaultButtonStyle(.plain)).foregroundStyle(Palette.accent)
        } else {
          VStack(spacing: 12) {
            SecureField(store.t("主密码", "Master password"), text: $password).textFieldStyle(
              .roundedBorder
            ).focused($focused).onSubmit(submit)
            if !store.exists {
              SecureField(store.t("再次输入主密码", "Confirm master password"), text: $confirmation)
                .textFieldStyle(.roundedBorder).onSubmit(submit)
            }
          }.controlSize(.large)
          Button(
            store.exists ? store.t("解锁", "Unlock") : store.t("创建资料库", "Create vault"),
            action: submit
          )
          .buttonStyle(VaultButtonStyle(.primary)).tint(Palette.blue).controlSize(.large)
          .keyboardShortcut(
            .defaultAction
          )
          .disabled(
            password.isEmpty || (!store.exists && (password.count < 10 || password != confirmation))
          )
          if !store.exists && !confirmation.isEmpty && password != confirmation {
            Text(store.t("两次输入的主密码不一致。", "The master passwords do not match.")).font(.caption)
              .foregroundStyle(.red)
          }
          if !store.exists {
            Text(
              store.t(
                "至少 10 个字符。请妥善保管主密码，应用无法替你找回。",
                "At least 10 characters. Keep it safe; the app cannot recover it for you.")
            ).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }
        }
        if let message = store.authenticationError {
          Text(message).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            .accessibilityIdentifier("unlock.error")
        }
      }
      .frame(width: 380).disabled(store.busy || !store.ready)
      Spacer()
      HStack {
        Text(store.t("数据保存在本机", "Your data stays on this device")).foregroundStyle(.secondary)
        Spacer()
        Picker("Language", selection: $store.language) {
          Text("简体中文").tag("zh")
          Text("English").tag("en")
        }.labelsHidden().frame(width: 125)
          .onChange(of: store.language) { UserDefaults.standard.set($0, forKey: "language") }
      }.font(.caption).padding(28)
    }
    .background(Palette.surface)
    .onAppear { focused = true }
    .onChange(of: store.busy) { if !$0 { focused = true } }
    .onChange(of: password) { _ in store.authenticationError = nil }
    .onDisappear {
      password = ""
      confirmation = ""
    }
  }

  private func submit() {
    guard !password.isEmpty, store.exists || (password == confirmation && password.count >= 10)
    else { return }
    let candidate = password
    password = ""
    confirmation = ""
    Task { await store.authenticate(password: candidate, create: !store.exists) }
  }
}
