import SwiftUI

struct MobileRelayPasswordField: View {
  @Binding var value: String
  var title: String
  @State private var visible = false
  var body: some View {
    HStack {
      Group {
        if visible { TextField(title, text: $value) }
        else { SecureField(title, text: $value) }
      }.textInputAutocapitalization(.never).autocorrectionDisabled()
      Button { visible.toggle() } label: {
        Image(systemName: visible ? "eye.slash" : "eye")
      }.accessibilityLabel(visible ? "隐藏密码 / Hide password" : "显示密码 / Show password")
    }
  }
}

struct MobileRelayPasswordSettings: View {
  @ObservedObject var relay: VaultRelay
  var t: (String, String) -> String
  @State private var password = ""
  var body: some View {
    DisclosureGroup(t("服务器密码", "Server password")) {
      Text(relay.config.endpoint).font(.caption).textSelection(.enabled)
      MobileRelayPasswordField(value: $password, title: t("服务器密码", "Server password"))
      Text(t("修改密码会保留设备组身份。此密码不是本机主密码。", "Updating this password preserves your group identity. It is not your vault password."))
        .font(.caption).foregroundStyle(.secondary)
      Button(t("保存服务器密码", "Save server password")) { Task { await relay.updateServerPassword(password) } }
        .disabled(password.isEmpty || relay.groupBusy)
    }.onAppear { password = relay.config.serverPassword ?? "" }
  }
}

struct MobileRelayEnrollment: View {
  @ObservedObject var relay: VaultRelay
  var t: (String, String) -> String
  @State private var joining = false
  @State private var endpoint = ""
  @State private var password = ""
  @State private var groupName = ""
  @State private var deviceName = ""
  @State private var invitation = ""
  @State private var inspected = ""
  @State private var carriedPassword = false
  @State private var scanning = false
  @State private var error: String?

  @State private var editing = false
  @State private var initialized = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(relay.creatingGroup ? t("继续创建", "Continue creation") : t("创建新设备组", "Create group")) {
        joining = false; editing = true
      }
      if !relay.creatingGroup {
        Button(t("扫码或手动加入", "Scan or enter an invitation")) { joining = true; editing = true }
      }
    }
    .sheet(isPresented: $editing) {
      NavigationStack {
        ScrollView {
          fields.padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(joining ? t("加入设备组", "Join group") : t("创建设备组", "Create group"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
          Button(t("返回", "Back")) { editing = false }.disabled(relay.groupBusy)
        } }
        .safeAreaInset(edge: .bottom) {
          confirmButton.padding(16).background(.regularMaterial)
        }
        .interactiveDismissDisabled(relay.groupBusy)
        .disabled(relay.groupBusy)
      }
    }
  }
  private var confirmButton: some View {
    Button { submit() } label: {
      Text(joining ? t("确认加入", "Confirm join") : relay.creatingGroup ? t("重试创建", "Retry creation") : t("创建设备组", "Create group"))
        .frame(maxWidth: .infinity).padding(.vertical, 6)
    }.buttonStyle(.borderedProminent).disabled(relay.groupBusy)
  }
  private var fields: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker(t("接入方式", "Connection"), selection: $joining) {
        Text(t("创建", "Create")).tag(false)
        Text(t("加入", "Join")).tag(true)
      }.pickerStyle(.segmented).disabled(relay.creatingGroup)
      TextField(t("本机名称", "Device name"), text: $deviceName).disabled(relay.creatingGroup)
      if joining {
        Button { scanning = true } label: { Label(t("扫描邀请二维码", "Scan invitation"), systemImage: "qrcode.viewfinder") }
        Text(t("无法使用相机时，可在下方粘贴邀请。读取后请核对服务器和密码，再确认加入。", "You can also paste an invitation below. Review the server and password before confirming."))
          .font(.caption).foregroundStyle(.secondary)
        TextField(t("邀请链接或旧版邀请内容", "Invitation link or legacy invitation"), text: $invitation, axis: .vertical)
          .lineLimit(2...5).textInputAutocapitalization(.never).autocorrectionDisabled()
          .onChange(of: invitation) { _ in inspected = ""; error = nil }
        Button(t("读取邀请", "Read invitation")) { inspect(invitation) }
        if !inspected.isEmpty {
          Text(t("确认加入设备组", "Confirm group invitation")).font(.headline)
          Text(endpoint).font(.callout).textSelection(.enabled)
          Text(carriedPassword
               ? t("已从邀请链接读取服务器密码，可显示或修改。", "Server password read from the invitation. You can reveal or edit it.")
               : t("邀请未携带服务器密码，请向邀请人获取后填写。", "Ask the inviter for the server password and enter it below."))
            .font(.caption).foregroundStyle(.secondary)
        }
      } else {
        TextField("wss://host/relay/v1/ws", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(relay.creatingGroup)
        TextField(t("设备组名称（必填）", "Group name (required)"), text: $groupName)
          .disabled(relay.creatingGroup)
      }
      MobileRelayPasswordField(value: $password, title: t("服务器密码（必填）", "Server password (required)"))
      Text(t("服务器密码仅用于中继访问，不是主密码或端到端密钥。加入后仍需单独授权密码库。", "This password grants relay access only. Vault access requires separate authorization after joining."))
        .font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("relay-enrollment-error") }
      if let failure = relay.failure { Text(failure).foregroundStyle(.red) }
      if relay.creatingGroup {
        Text(t("创建身份和服务器地址已保存，修改密码后可重试。", "Creation identity and endpoint saved. Correct the password and retry."))
          .font(.caption)
      }
    }
    .onAppear {
      guard !initialized else { return }; initialized = true
      deviceName = t("我的 iPhone", "My iPhone")
      if let draft = relay.pendingCreationNames { groupName = draft.group; deviceName = draft.device }
      endpoint = relay.config.endpoint
      password = relay.config.serverPassword ?? ""
    }
    .sheet(isPresented: $scanning) {
      MobileQRImport(apply: { _ in }, payloadHandler: { value in
        invitation = value
        scanning = false
        // Defer inspection until the input change has invalidated the old preview.
        Task { @MainActor in await Task.yield(); inspect(value) }
      })
    }
  }
  private func inspect(_ text: String) {
    do {
      let preview = try VaultRelay.inspectInvitation(text)
      endpoint = preview.endpoint
      password = preview.password ?? ""
      carriedPassword = preview.password != nil
      inspected = text
      error = nil
    } catch {
      inspected = ""
      self.error = t("无法读取邀请，请检查完整内容或向邀请人索取新邀请。", "Cannot read this invitation. Check the complete text or request a new invitation.")
    }
  }
  private func submit() {
    do {
      guard !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RelayErrorForForm.required }
      _ = try VaultRelay.validateEndpoint(endpoint)
      try VaultRelay.validateServerPassword(password)
      if joining {
        guard !inspected.isEmpty, inspected == invitation else { throw RelayErrorForForm.required }
        let preview = try VaultRelay.inspectInvitation(invitation)
        guard preview.endpoint == endpoint else { throw RelayErrorForForm.required }
        Task { await relay.joinGroup(invitation, deviceName: deviceName, password: password) }
      } else {
        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RelayErrorForForm.required }
        Task { await relay.createGroup(endpoint: endpoint, name: groupName, deviceName: deviceName, password: password) }
      }
      error = nil
    } catch {
      self.error = t("请填写本机名称、有效 WSS 地址、服务器密码与组名；加入前请先读取邀请。密码须为 8–128 位不含空格的可打印 ASCII 字符。", "Enter a device name, valid WSS endpoint, server password and group name. Read the invitation before joining. Passwords require 8–128 printable ASCII characters without spaces.")
    }
  }
  private enum RelayErrorForForm: Error { case required }
}
