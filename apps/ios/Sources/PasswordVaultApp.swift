import SwiftUI
import UniformTypeIdentifiers

@main
struct PasswordVaultApp: App {
  @Environment(\.scenePhase) private var phase
  @StateObject private var store = MobileVaultStore()
  var body: some Scene {
    WindowGroup {
      Group {
        if store.unlocked { MobileTabs() } else { MobileUnlockView() }
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
        if let notice = store.notice, store.unlocked {
          Text(notice).font(.caption).padding(12).background(.regularMaterial, in: Capsule())
            .padding(.bottom, 85).allowsHitTesting(false)
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
      .sheet(item: $store.recoveredDraft) {
        MobileEntryEditor(item: $0, recovered: true).environmentObject(store)
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
  @State private var selected: Destination? = .passwords
  @EnvironmentObject private var store: MobileVaultStore
  var body: some View {
    if sizeClass == .regular {
      NavigationSplitView {
        List(selection: $selected) {
          ForEach([Destination.passwords, .notes, .codes, .wallets, .settings], id: \.self) {
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
          } else {
            MobileEntryList(destination: selected ?? .passwords)
          }
        }.id(selected)
      }.navigationSplitViewStyle(.balanced)
    } else {
      TabView {
        ForEach([Destination.passwords, .notes, .codes, .wallets], id: \.self) { kind in
          NavigationStack { MobileEntryList(destination: kind) }
            .tabItem { Label(kind.title(chinese: store.chinese), systemImage: kind.symbol) }
        }
        NavigationStack { MobileSettingsView() }
          .tabItem { Label(store.t("设置", "Settings"), systemImage: "gearshape") }
      }
    }
  }
}

struct MobileUnlockView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var password = ""
  @State private var confirmation = ""
  @State private var legacyPassword = ""
  @State private var importing = false
  @State private var pendingImport: URL?
  @State private var backupPassword = ""
  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.system(size: 45)).foregroundStyle(.blue)
            Text(
              store.exists
                ? store.t("解锁资料库", "Unlock your vault") : store.t("留下重要的资料", "Keep what matters")
            ).font(.title.bold())
            Text(
              store.exists
                ? store.t("你的资料仅在解锁后显示。", "Your information is visible only when unlocked.")
                : store.t(
                  "创建本机加密资料库。请妥善保存主密码。",
                  "Create an encrypted vault on this device. Keep your master password safe.")
            ).foregroundStyle(.secondary)
          }.padding(.vertical, 16)
          if store.legacyAvailable {
            Text(
              store.t(
                "发现旧版资料。验证旧密码后迁移到新加密库，原文件保留。",
                "Legacy data found. Verify its password to migrate; original files are retained."))
            SecureField(store.t("旧版主密码", "Legacy master password"), text: $legacyPassword)
          }
          SecureField(store.t("主密码", "Master password"), text: $password).textContentType(.password)
            .accessibilityIdentifier("vault.password")
          if !store.exists {
            SecureField(store.t("再次输入主密码", "Confirm master password"), text: $confirmation)
              .textContentType(.newPassword)
          }
          Button {
            let value = password
            Task {
              await store.authenticate(value, create: !store.exists, legacyPassword: legacyPassword)
              password = ""
              confirmation = ""
              legacyPassword = ""
            }
          } label: {
            HStack {
              Spacer()
              if store.busy { ProgressView() }
              Text(store.exists ? store.t("解锁", "Unlock") : store.t("创建资料库", "Create vault"))
              Spacer()
            }
          }.disabled(
            !store.ready || store.busy || password.isEmpty
              || (!store.exists && (password.isEmpty || password != confirmation))
          ).accessibilityIdentifier("vault.unlock")
        }
        if !store.exists {
          Section {
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
            Button(store.t("使用 Face ID / Touch ID", "Use Face ID / Touch ID")) {
              Task { await store.authenticateBiometric() }
            }.disabled(store.busy)
          }
        }
        Section {
          Picker("Language", selection: $store.language) {
            Text("简体中文").tag("zh")
            Text("English").tag("en")
          }.onChange(of: store.language) { UserDefaults.standard.set($0, forKey: "language") }
        } footer: {
          Text(
            store.t(
              "资料加密保存在本机。主密码不会保存。",
              "Data is encrypted on this device. The master password is not stored."))
        }
      }.navigationTitle("PasswordVault")
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
