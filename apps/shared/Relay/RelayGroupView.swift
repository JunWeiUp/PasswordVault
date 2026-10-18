import SwiftUI

struct RelayGroupView: View {
  @ObservedObject var relay: VaultRelay
  var t: (String, String) -> String = { zh, _ in zh }
  @State private var endpoint = "wss://eglish.top/relay/v1/ws"
  @State private var name = ""
  @State private var deviceName = ""
  @State private var input = ""
  @State private var grantManager = false
  @State private var automaticJoin = true
  @State private var confirmation: String?
  @State private var target: VaultRelay.GroupMember?
  @State private var renamed = ""
  #if os(iOS)
  @State private var scanning = false
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(t("设备组", "Device group"), systemImage: "network").font(.headline)
      Text(t("设备组用于安全接入中继。加入后仍需 Mac 单独授权，才会同步密码库。", "Join securely first, then authorize vault synchronization separately on Mac."))
        .font(.caption).foregroundStyle(.secondary)
      if relay.groupBusy { ProgressView(t("正在处理", "Working…")) }
      if relay.groupInvalid {
        Text(t("本机接入已失效，缓存名单不可用于授权。", "Access invalid; cached members are hidden."))
        Button(t("清除本机接入", "Clear local access"), role: .destructive) { confirmation = "clear" }
      } else if relay.isLegacyGroup {
        Text(t("现有手动接入仍保留。要改用设备组，请先明确清除本机接入，再创建或加入；旧令牌需要管理员另行撤销。", "Manual access is retained. Clear local access before migrating; an administrator must separately revoke old credentials."))
          .font(.caption)
        Button(t("迁移到设备组…", "Migrate to device group…")) { confirmation = "clear" }
      } else if relay.hasManagedGroup {
        HStack {
          Text(relay.groupName.isEmpty ? relay.config.group : relay.groupName).font(.title3)
          Spacer()
          Button(t("刷新名单", "Refresh")) { Task { await relay.refreshGroup() } }
        }
        if !relay.groupFresh { Text(t("名单尚未验证，请刷新后管理设备。", "Refresh to verify membership.")).foregroundStyle(.secondary) }
        ForEach(relay.groupMembers) { member in
          HStack {
            Image(systemName: member.online ? "circle.fill" : "circle").foregroundStyle(member.online ? .green : .secondary)
            VStack(alignment: .leading) {
              Text(member.name + (member.id == relay.config.device ? t(" · 本机", " · This device") : ""))
              Text((member.manager ? t("管理员", "Manager") : t("成员", "Member")) + " · " + (member.online ? t("在线", "Online") : t("离线", "Offline")))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if relay.config.role == "hub" && member.id != relay.config.device {
              VStack(alignment: .trailing, spacing: 4) {
                Toggle(t("查看并同步修改", "View and sync changes"), isOn: Binding(
                  get: { relay.vaultAccessEnabled(member.id) },
                  set: { value in Task { await relay.setVaultAccess(member.id, enabled: value) } }
                )).toggleStyle(.switch).disabled(!relay.groupManager && !relay.vaultAccessEnabled(member.id))
                  .accessibilityIdentifier("vault-access-" + member.id)
                Text(relay.vaultAccessPending(member.id)
                     ? t("等待设备解锁并确认", "Waiting for device to unlock and confirm")
                     : (relay.vaultAccessEnabled(member.id) ? t("已授权", "Authorized") : t("未授权", "Not authorized")))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            if relay.groupManager || member.id == relay.config.device {
              Menu {
                Button(t("改名", "Rename")) { target = member; renamed = member.name }
                if relay.groupManager && member.id != relay.config.device {
                  Button(t("移除", "Remove"), role: .destructive) { confirmation = "remove:" + member.id }
                }
              } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.automatic)
            }
          }
        }
        if relay.groupManager {
          Toggle(t("扫描后自动加入", "Join automatically after scanning"), isOn: $automaticJoin)
            .disabled(!relay.groupInvite.isEmpty)
          Button(t("添加设备", "Add device")) { Task { grantManager = false; await relay.inviteToGroup(automatic: automaticJoin) } }
        }
        if !relay.groupInvite.isEmpty {
          RelayQRCode(text: relay.groupInvite)
          Text(relay.automaticGroupJoin ? t("扫描即可加入普通成员；密码库需另行授权。", "Scan to join as a member; vault access requires separate authorization.") : t("需核对配对码并手动批准。", "Compare codes and approve manually."))
          Text(t("邀请有效期 10 分钟，仅限一台设备。请通过可信渠道传递。", "Valid for 10 minutes, one device.")).font(.caption)
          DisclosureGroup(t("查看邀请内容（可复制）", "Invitation text")) {
            Text(relay.groupInvite).font(.caption2).textSelection(.enabled)
          }
          HStack {
            if !relay.automaticGroupJoin {
              Button(t("查看加入申请", "Check request")) { Task { await relay.checkGroupRequest() } }
            }
            Button(t("取消邀请", "Cancel invitation")) { Task { await relay.cancelGroupInvitation() } }
          }
        }
        if !relay.automaticGroupJoin && !relay.applicantName.isEmpty {
          Text(t("申请设备：", "Applicant: ") + relay.applicantName)
          Text(relay.groupCode).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
          Toggle(t("同时授予设备组管理权限", "Grant group management"), isOn: $grantManager)
          Button(t("两端配对码一致，批准加入", "Codes match, approve")) { Task { await relay.approveGroupRequest(manager: grantManager) } }
        }
        HStack {
          Button(t("退出设备组…", "Leave…"), role: .destructive) { confirmation = "leave" }
          if relay.groupManager { Button(t("解散设备组…", "Disband…"), role: .destructive) { confirmation = "disband" } }
        }
      } else if relay.joiningGroup {
        Text(relay.automaticGroupJoin ? t("自动加入尚未完成，请重试。", "Automatic join is incomplete. Retry to continue.") : t("请让邀请方核对以下配对码并批准，再完成加入。", "Ask the inviter to compare and approve."))
        Text(relay.groupCode).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
        Button(t("完成加入", "Finish joining")) { Task { await relay.finishGroupJoin() } }
        Button(t("重新发送申请", "Resend request")) { Task { await relay.retryGroupJoin() } }
        Button(t("放弃本机申请…", "Abandon local request…"), role: .destructive) { confirmation = "clear" }
      } else {
        Text(t("本机名称", "Device name")).font(.subheadline)
        TextField(t("本机名称", "Device name"), text: $deviceName).textFieldStyle(.roundedBorder)
        Text(t("设备组名称", "Group name")).font(.subheadline)
        TextField(t("设备组名称", "Group name"), text: $name).textFieldStyle(.roundedBorder)
        DisclosureGroup(t("服务地址", "Relay endpoint")) {
          TextField("wss://host/relay/v1/ws", text: $endpoint).textFieldStyle(.roundedBorder).autocorrectionDisabled()
        }
        Button(relay.creatingGroup ? t("重试创建", "Retry creation") : t("创建新设备组", "Create group")) {
          Task { await relay.createGroup(endpoint: endpoint, name: name, deviceName: deviceName) }
        }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || deviceName.trimmingCharacters(in: .whitespaces).isEmpty)
        if relay.creatingGroup {
          Text(t("创建请求已保存；重试会沿用相同身份。", "The original creation request is retained.")).font(.caption)
          Button(t("清除本机创建草稿…", "Clear local draft…")) { confirmation = "clear" }
        } else {
          Divider()
          Text(t("加入已有设备组", "Join an existing group")).font(.subheadline)
          #if os(iOS)
          Button(t("扫描设备组邀请", "Scan group invitation")) { scanning = true }
          #endif
          RelayPasteInput(text: $input, placeholder: t("粘贴另一台设备生成的邀请内容", "Paste the invitation from another device"))
          Button(t("提交加入申请", "Request to join")) { Task { await relay.joinGroup(input, deviceName: deviceName) } }
            .disabled(input.isEmpty || deviceName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .disabled(relay.groupBusy)
    .onAppear {
      if !relay.groupInvite.isEmpty { automaticJoin = relay.automaticGroupJoin }
      if deviceName.isEmpty { deviceName = relay.config.role == "hub" ? t("我的 Mac", "My Mac") : t("我的手机", "My phone") }
      if name.isEmpty { name = t("我的设备", "My devices") }
      if !relay.config.endpoint.isEmpty { endpoint = relay.config.endpoint }
    }
    .onChange(of: relay.groupInvite) { value in
      if !value.isEmpty { automaticJoin = relay.automaticGroupJoin }
    }
    .confirmationDialog(t("确认设备组操作", "Confirm group action"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
      Button(t("确认", "Confirm"), role: .destructive) {
        let operation = confirmation ?? ""; confirmation = nil
        Task {
          if operation == "clear" { await relay.clearLocalGroup() }
          else if operation.hasPrefix("remove:") { await relay.removeGroupMember(String(operation.dropFirst(7))) }
          else { await relay.leaveGroup(disband: operation == "disband") }
        }
      }
      Button(t("取消", "Cancel"), role: .cancel) { confirmation = nil }
    } message: {
      Text(confirmation == "disband"
        ? t("解散会撤销全组中继访问。各设备已下载的资料不会被远程删除。", "Disbanding revokes relay access for all members. Downloaded vault data cannot be remotely erased.")
        : confirmation?.hasPrefix("remove:") == true
          ? t("将撤销该设备的中继访问与本机同步授权；已下载资料无法远程删除。", "Revoke this device’s relay access and local vault authorization. Downloaded data remains on the device.")
          : confirmation == "clear"
            ? t("仅清除本机接入，不能代替远端撤销。保留本地资料，并加密归档旧同步记录；新接入使用新设备 ID。", "Clear local access only; this does not revoke remote access. Keep local data, archive encrypted sync history and rotate the device ID.")
            : t("退出后本机停止中继同步，其他成员继续使用。保留本地资料，并加密归档旧同步记录。最后一名管理员需先指定其他管理员或解散。", "Stop local relay sync and retain local data and encrypted sync history. Other members stay connected. The last manager must add another manager or disband."))
    }
    .sheet(item: $target) { member in
      VStack(spacing: 16) {
        Text(t("设备名称", "Device name")).font(.headline)
        TextField(t("名称", "Name"), text: $renamed).textFieldStyle(.roundedBorder)
        HStack {
          Button(t("取消", "Cancel")) { target = nil }
          Button(t("保存", "Save")) { let value = renamed; target = nil; Task { await relay.renameGroupMember(member.id, name: value) } }
            .disabled(renamed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }.padding(24).frame(minWidth: 280)
    }
    #if os(iOS)
    .sheet(isPresented: $scanning) { MobileQRImport(apply: { _ in }, payloadHandler: { value in input = value; scanning = false; Task { await relay.joinGroup(value, deviceName: deviceName) } }) }
    #endif
  }
}
