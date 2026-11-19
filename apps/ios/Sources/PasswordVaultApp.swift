import SwiftUI
import UniformTypeIdentifiers

@main
struct PasswordVaultApp: App {
  @Environment(\.scenePhase) private var phase
  @StateObject private var store = MobileVaultStore()
  var body: some Scene {
    WindowGroup {
      Group {
        if store.unlocked {
          if store.offerBiometrics { MobileBiometricOffer() } else { MobileTabs() }
        } else {
          MobileUnlockView()
        }
      }
      .environmentObject(store)
      .background(MobileActivityObserver(onActivity: store.activity).allowsHitTesting(false))
      .tint(.blue)
      .preferredColorScheme(
        store.settings["theme"]?.string == "dark"
          ? .dark : store.settings["theme"]?.string == "light" ? .light : nil
      )
      .privacySensitive()
      .overlay(alignment: .bottom) {
        if store.unlocked, store.undoTrashID != nil {
          HStack(spacing: 16) {
            Label(store.t("已移到回收站", "Moved to Trash"), systemImage: "trash").font(.subheadline)
            Button(store.t("撤销", "Undo")) { Task { await store.undoTrash() } }
              .font(.subheadline.weight(.semibold)).accessibilityIdentifier("undo.trash")
          }
          .padding(.horizontal, 18).padding(.vertical, 12)
          .background(.regularMaterial, in: Capsule())
          .padding(.bottom, 85)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let notice = store.notice, store.unlocked {
          Text(notice).font(.caption).padding(12).background(.regularMaterial, in: Capsule())
            .padding(.bottom, 85).allowsHitTesting(false)
        }
      }
      .task(id: store.undoTrashID) {
        if store.undoTrashID != nil {
          try? await Task.sleep(nanoseconds: 6_000_000_000)
          if !Task.isCancelled { store.undoTrashID = nil }
        }
      }
      .task(id: store.notice) {
        if store.notice != nil {
          try? await Task.sleep(nanoseconds: 3_000_000_000)
          if !Task.isCancelled { store.notice = nil }
        }
      }
      .overlay {
        if phase != .active {
          Color(uiColor: .systemBackground).ignoresSafeArea().overlay {
            Label("PasswordVault", systemImage: "lock.shield").font(.title2)
          }
        }
      }
      .task { await store.start() }
      .sheet(item: $store.recoveredDraft) { item in
        Group { if item.type == "secureNote" { MobileRichNoteEditor(item: item) } else { MobileEntryEditor(item: item, recovered: true) } }.environmentObject(store)
      }
      .onChange(of: phase) { value in
        if value == .background && !store.systemFileFlow { store.lock() }
      }
      .alert(
        store.t("操作未完成", "Could not complete"),
        isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
      ) {
        Button(store.t("好", "OK"), role: .cancel) { store.error = nil }
      } message: {
        Text(store.error ?? "")
      }
    }
  }
}

struct MobileTabs: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var selected: Destination? = StartTab.current
  @State private var tab: Destination = StartTab.current
  @EnvironmentObject private var store: MobileVaultStore
  var body: some View {
    if sizeClass == .regular {
      NavigationSplitView {
        List(selection: $selected) {
          ForEach([Destination.notes, .passwords, .codes, .wallets, .settings], id: \.self) {
            kind in
            NavigationLink(value: kind) {
              Label(kind.title(chinese: store.chinese), systemImage: kind.symbol)
            }
          }
        }.navigationTitle("PasswordVault")
      } detail: {
        NavigationStack {
          if selected == .settings {
            MobileSettingsView()
          } else if (selected ?? .notes) == .notes {
            MobileNotesView()
          } else {
            MobileEntryList(destination: selected ?? .notes)
          }
        }.id(selected)
      }.navigationSplitViewStyle(.balanced)
    } else {
      TabView(selection: $tab) {
        ForEach([Destination.notes, .passwords, .codes, .wallets], id: \.self) { kind in
          NavigationStack {
            if kind == .notes { MobileNotesView() } else { MobileEntryList(destination: kind) }
          }
            .tabItem { Label(kind.title(chinese: store.chinese), systemImage: kind.symbol) }
            .tag(kind)
        }
        NavigationStack { MobileSettingsView() }
          .tabItem { Label(store.t("设置", "Settings"), systemImage: "gearshape") }
          .tag(Destination.settings)
      }
    }
  }
}

struct MobileUnlockView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var password = ""
  @State private var confirmation = ""
  @State private var showPassword = false
  @State private var legacyPassword = ""
  @State private var importing = false
  @State private var pendingImport: URL?
  @State private var backupPassword = ""
  /// First run: the welcome step comes before setting the master password.
  @State private var started = false
  @State private var otherDevice = false
  var body: some View {
    if !store.ready {
      ProgressView()
    } else if !store.exists && !started {
      MobileWelcome(start: { other in
        otherDevice = other
        started = true
      })
    } else {
      form
    }
  }
  private var form: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            Image(systemName: store.exists ? "lock.shield.fill" : "key.fill").font(.system(size: 45)).foregroundStyle(.blue)
            Text(
              store.exists
                ? store.t("PasswordVault 已锁定", "PasswordVault is locked") : store.t("设置主密码", "Set a master password")
            ).font(.title.bold())
            Text(
              store.exists
                ? (UserDefaults.standard.bool(forKey: "biometricEnabled")
                  ? store.t("输入主密码，或使用\(MobileBiometrics.name(store.t))解锁。", "Enter your master password or use \(MobileBiometrics.name(store.t)).")
                  : store.t("输入主密码以解锁。", "Enter your master password to unlock."))
                : store.t(
                  "主密码用于加密本机密码库，忘记后无法找回（除非设置恢复密钥）。至少 1 个字符；加密强度不会因长度降低，但建议使用长密码。",
                  "The master password encrypts this vault and can't be recovered unless you set up a recovery key. At least 1 character; encryption strength stays the same, but a long password is recommended.")
            ).foregroundStyle(.secondary)
            if !store.exists {
              OnboardingDots(step: 1)
              if otherDevice {
                Text(store.t(
                  "设置主密码后，可在 设置 › 同步与设备 中扫描邀请加入设备组；也可以在下方从备份创建。",
                  "After setting the password, scan an invitation in Settings › Sync & devices, or create the vault from a backup below."))
                  .font(.footnote).foregroundStyle(.secondary)
              }
            }
          }.padding(.vertical, 16)
          if store.legacyAvailable {
            Text(
              store.t(
                "发现旧版资料。验证旧密码后迁移到新加密库，原文件保留。",
                "Legacy data found. Verify its password to migrate; original files are retained."))
            SecureField(store.t("旧版主密码", "Legacy master password"), text: $legacyPassword)
          }
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Group {
                if showPassword {
                  TextField(store.t("主密码", "Master password"), text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } else {
                  SecureField(store.t("主密码", "Master password"), text: $password)
                }
              }
              .textContentType(.password)
              .accessibilityIdentifier("vault.password")
              .onChange(of: password) { _ in store.unlockError = nil }
              .onSubmit { if store.exists && !password.isEmpty { submit() } }
              Button {
                showPassword.toggle()
              } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.borderless)
              .accessibilityLabel(showPassword ? store.t("隐藏主密码", "Hide master password") : store.t("显示主密码", "Show master password"))
            }
            if let message = store.unlockError {
              Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote).foregroundStyle(.red)
                .accessibilityIdentifier("vault.password.error")
            }
          }
          if !store.exists {
            SecureField(store.t("再次输入主密码", "Confirm master password"), text: $confirmation)
              .textContentType(.newPassword)
            if !confirmation.isEmpty {
              Text(password == confirmation ? store.t("✓ 一致", "✓ Matches") : store.t("两次输入不一致", "Passwords don't match"))
                .font(.footnote).foregroundStyle(password == confirmation ? Color.green : Color.red)
            }
          }
        }
        Section {
          Button(action: submit) {
            HStack(spacing: 8) {
              if store.busy { ProgressView().tint(.white) }
              Text(store.exists ? store.t("解锁", "Unlock") : store.t("创建资料库", "Create vault"))
                .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(
            !store.ready || store.busy || password.isEmpty
              || (!store.exists && (password.isEmpty || password != confirmation))
          )
          .accessibilityIdentifier("vault.unlock")
          .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
          .listRowBackground(Color.clear)
        }
        if !store.exists {
          Section {
            NavigationLink(store.t("使用恢复密钥", "Use recovery key")) { MobileRecoveryView() }
            Button(store.t("从已有备份创建资料库…", "Create vault from a backup…")) { importing = true }
              .disabled(password.isEmpty || password != confirmation || store.busy)
          } footer: {
            Text(
              store.t(
                "先填写并确认新主密码；选择备份后再输入这份文件的原密码。原文件保留。",
                "Enter and confirm a new master password first, then choose a backup and enter its original password. The source file is retained."
              ))
          }
        }
        if store.exists && UserDefaults.standard.bool(forKey: "biometricEnabled") {
          Section {
            Button(store.t("使用", "Use ") + MobileBiometrics.name(store.t) + store.t("解锁", "")) {
              Task { await store.authenticateBiometric() }
            }.disabled(store.busy)
          }
        }
        if store.exists { Section { NavigationLink(store.t("使用恢复密钥", "Use recovery key")) { MobileRecoveryView() } } }
        Section {
          Picker(store.t("语言 / Language", "Language"), selection: $store.language) {
            Text("简体中文").tag("zh")
            Text("English").tag("en")
          }.onChange(of: store.language) { UserDefaults.standard.set($0, forKey: "language") }
        } footer: {
          Text(
            store.t(
              "资料加密保存在本机。主密码不会保存。",
              "Data is encrypted on this device. The master password is not stored."))
        }
      }.navigationTitle(store.exists ? "PasswordVault" : store.t("设置主密码", "Master password"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if !store.exists {
            ToolbarItem(placement: .navigationBarLeading) {
              Button(store.t("返回", "Back")) { started = false }.disabled(store.busy)
            }
          }
        }
        .fileImporter(
          isPresented: $importing, allowedContentTypes: [.data, .json, .commaSeparatedText]
        ) { result in
          if case .success(let url) = result { pendingImport = url }
        }
        .alert(
          store.t("备份文件密码", "Backup file password"),
          isPresented: Binding(
            get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })
        ) {
          SecureField(store.t("这份文件的原密码", "Original password for this file"), text: $backupPassword)
          Button(store.t("导入并创建", "Import and create")) {
            guard let url = pendingImport else { return }
            pendingImport = nil
            Task {
              let access = url.startAccessingSecurityScopedResource()
              defer { if access { url.stopAccessingSecurityScopedResource() } }
              do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 64 * 1024 * 1024 else { throw VaultError.InvalidData }
                let data = try Data(contentsOf: url)
                guard data.count <= 64 * 1024 * 1024,
                  let content = String(data: data, encoding: .utf8)
                else { throw VaultError.InvalidData }
                await store.createFromBackup(
                  content, filePassword: backupPassword, password: password,
                  kind: url.pathExtension.lowercased() == "csv" ? "csv" : "json")
                password = ""
                confirmation = ""
                backupPassword = ""
              } catch { store.report(error) }
            }
          }
          Button(store.t("取消", "Cancel"), role: .cancel) {
            pendingImport = nil
            backupPassword = ""
          }
        } message: {
          Text(store.t("未加密的 JSON / CSV 可留空。", "Leave blank for unencrypted JSON / CSV."))
        }
    }
  }
}

extension MobileUnlockView {
  fileprivate func submit() {
    let value = password
    let create = !store.exists
    Task {
      await store.authenticate(value, create: create, legacyPassword: legacyPassword)
      // A wrong password stays in the field so it can be corrected; anything else is cleared.
      if store.unlockError == nil { password = "" }
      confirmation = ""
      legacyPassword = ""
    }
  }
}

/// Step indicator for the three first-run steps.
struct OnboardingDots: View {
  let step: Int
  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<3) { index in
        Capsule().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
          .frame(width: index == step ? 18 : 6, height: 6)
      }
    }.accessibilityHidden(true)
  }
}

/// First-run welcome step.
struct MobileWelcome: View {
  @EnvironmentObject private var store: MobileVaultStore
  let start: (_ otherDevice: Bool) -> Void
  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(.blue).padding(.top, 40)
        Text(store.t("欢迎使用 PasswordVault", "Welcome to PasswordVault")).font(.title.bold())
          .multilineTextAlignment(.center)
        Text(store.t("账号、验证码、钱包和笔记，本机加密保存，可与你的其他设备端到端加密同步。",
          "Accounts, codes, wallets and notes, encrypted on this device and synced end-to-end with your other devices."))
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
        VStack(alignment: .leading, spacing: 16) {
          feature("lock", store.t("只有你能打开", "Only you can open it"), store.t("主密码不会离开这台设备", "Your master password never leaves this device"))
          feature("arrow.triangle.2.circlepath", store.t("与其他设备同步", "Sync with your devices"), store.t("扫码加入设备组即自动双向同步；中继只转发密文", "Scan to join a device group and sync both ways; the relay only forwards ciphertext"))
          feature("person.badge.key", store.t("在任何应用中填充", "Fill in any app"), store.t("系统自动填充与通行密钥", "System AutoFill and passkeys"))
        }.padding(.vertical, 8)
        OnboardingDots(step: 0)
        Button { start(false) } label: {
          Text(store.t("新建密码库", "Create a vault")).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .accessibilityIdentifier("onboarding.start")
        Button(store.t("我已在其他设备上使用", "I already use it on another device")) { start(true) }
        Picker("Language", selection: $store.language) {
          Text("简体中文").tag("zh")
          Text("English").tag("en")
        }
        .pickerStyle(.segmented).frame(maxWidth: 260)
        .onChange(of: store.language) { UserDefaults.standard.set($0, forKey: "language") }
      }
      .padding(.horizontal, 24).padding(.bottom, 24)
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
  }
  private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol).font(.title3).foregroundStyle(.blue).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }
}

/// Last first-run step: offer biometric unlock (shown only when the device supports it).
struct MobileBiometricOffer: View {
  @EnvironmentObject private var store: MobileVaultStore
  var body: some View {
    let name = MobileBiometrics.name(store.t)
    VStack(spacing: 20) {
      Spacer()
      Image(systemName: name.contains("Touch") || name.contains("触控") ? "touchid" : "faceid")
        .font(.system(size: 60)).foregroundStyle(.blue)
      Text(store.t("使用\(name)解锁？", "Unlock with \(name)?")).font(.title.bold()).multilineTextAlignment(.center)
      Text(store.t("主密码仍然有效。设备新增\(name)数据后需要重新输入主密码。",
        "Your master password still works. After biometric data changes on this device, enter the master password again."))
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
      OnboardingDots(step: 2)
      Spacer()
      Button {
        Task {
          await store.enrollBiometrics()
          store.offerBiometrics = false
        }
      } label: {
        Text(store.t("启用\(name)解锁", "Turn on \(name)")).frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy)
      .accessibilityIdentifier("onboarding.biometric.enable")
      Button(store.t("以后再说", "Not now")) {
        store.offerBiometrics = false
        store.notice = store.t("可稍后在 设置 › 安全 中启用", "You can turn it on later in Settings › Security")
      }
      .accessibilityIdentifier("onboarding.biometric.skip")
    }
    .padding(24).frame(maxWidth: 520)
  }
}
