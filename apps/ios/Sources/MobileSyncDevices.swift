import SwiftUI

/// Settings › Sync & devices, laid out like the mobile design: a status card, the member list
/// with rename/remove, invitations, joining and leave/disband. Uses the relay's existing
/// actions only; the relay protocol is unchanged.
struct MobileSyncDevicesView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @ObservedObject var relay: VaultRelay
  @State private var memberTarget: VaultRelay.GroupMember?
  @State private var renaming: VaultRelay.GroupMember?
  @State private var newName = ""
  @State private var removing: VaultRelay.GroupMember?
  @State private var exit: Exit?
  @State private var inviting = false
  @State private var enrolling: Enrollment?
  @State private var grantManager = false
  @State private var meshConflicts: [MeshNoteConflict] = []
  @State private var resolvingConflict: MeshNoteConflict?

  struct MeshNoteConflict: Identifiable {
    let noteId: String
    let title: String
    let section: String
    let localDevice: String
    let remoteDevice: String
    var id: String { noteId }
  }

  enum Exit: String, Identifiable { case leave, disband; var id: String { rawValue } }
  struct Enrollment: Identifiable {
    let joining: Bool
    let scan: Bool
    var id: String { "\(joining)-\(scan)" }
  }

  private var t: (String, String) -> String { store.t }
  /// A usable personal device group; other states keep the detailed legacy controls.
  private var joined: Bool {
    relay.credentialsReady && relay.hasManagedGroup && !relay.groupInvalid && !relay.isLegacyGroup
  }

  var body: some View {
    Group {
      if joined {
        groupPage
      } else if relay.credentialsReady && !relay.hasManagedGroup && !relay.joiningGroup && !relay.isLegacyGroup
        && !relay.groupInvalid && !relay.creatingGroup {
        joinPage
      } else {
        // Pending joins, unfinished creation, legacy access and credential migration.
        ScrollView { RelaySettingsView(relay: relay, t: t).padding() }
      }
    }
    .navigationTitle(t("同步与设备", "Sync & devices"))
    .sheet(item: $enrolling) { MobileRelayEnrollmentSheet(relay: relay, t: t, joining: $0.joining, scanOnAppear: $0.scan) }
  }

  // MARK: Not in a group

  private var joinPage: some View {
    List {
      Section {
        VStack(spacing: 12) {
          Image(systemName: "qrcode.viewfinder").font(.system(size: 44)).foregroundStyle(.blue)
          Text(t("同步你的设备", "Sync your devices")).font(.title2.bold())
          Text(t(
            "在已入组设备上点「邀请设备」，然后扫描二维码加入；也可以在这台设备上创建设备组。组内所有设备自动双向同步，无需逐台确认。",
            "On a device already in the group, tap Invite device and scan the QR code to join, or create a group on this device. Every device in the group syncs both ways automatically."))
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
      }
      Section {
        Button { enrolling = Enrollment(joining: true, scan: true) } label: {
          Label(t("扫描邀请二维码", "Scan invitation QR code"), systemImage: "camera")
        }.accessibilityIdentifier("relay.join.scan")
        Button { enrolling = Enrollment(joining: true, scan: false) } label: {
          Label(t("粘贴邀请链接", "Paste invitation link"), systemImage: "doc.on.clipboard")
        }.accessibilityIdentifier("relay.join.paste")
        Button { enrolling = Enrollment(joining: false, scan: false) } label: {
          Label(t("创建设备组", "Create device group"), systemImage: "plus.circle")
        }.accessibilityIdentifier("relay.create")
      } footer: {
        Text(t("相机权限被拒绝时可改为粘贴链接。中继只转发密文。", "Without camera access, paste the link instead. The relay only forwards ciphertext."))
      }
      Section {
        NavigationLink(t("对等库与家庭库", "Peer & family libraries")) { peerLibraries }
      } footer: {
        Text(t("独立于个人设备组；成员与角色由各库单独管理。", "Separate from your device group; each library manages its own members and roles."))
      }
      if let failure = relay.failure { Section { Text(localized(failure)).foregroundStyle(.red) } }
    }
  }

  // MARK: In a group

  private var others: [VaultRelay.GroupMember] { relay.groupMembers.filter { $0.id != relay.config.device } }
  private var groupTitle: String { relay.groupName.isEmpty ? relay.config.group : relay.groupName }

  private var groupPage: some View {
    List {
      Section { statusCard }
      if relay.offline {
        Section {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(t("暂时无法连接中继，改动保留在本机", "Can't reach the relay; changes stay on this device")).font(.subheadline.weight(.medium))
              Text(t("联网后自动发送本机的修改，并接收其他设备的修改。", "When back online, this device sends its changes and receives the others'."))
                .font(.caption).foregroundStyle(.secondary)
            }
          } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            .accessibilityIdentifier("relay.offline.detail")
        }
      }
      Section {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text(t("L1 元数据优先 · 大附件按需拉取", "L1 metadata-first · on-demand large blobs")).font(.subheadline.weight(.medium))
            Text(t("密码与笔记优先同步，超过 512 KB 的附件不阻塞队列。非重叠编辑自动合并，冲突分支在本机保留 30 天历史。", "Credentials and notes sync first without blocking on >512 KB attachments. Disjoint edits auto-merge; competing branches stay in local history for 30 days."))
              .font(.caption).foregroundStyle(.secondary)
          }
        } icon: { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue) }
          .accessibilityIdentifier("relay.merge.note")
      }
      if !meshConflicts.isEmpty {
        Section {
          ForEach(meshConflicts) { cf in
            Button { resolvingConflict = cf } label: {
              HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                  Text(cf.title.isEmpty ? t("未命名笔记", "Untitled note") : cf.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                  Text(t("冲突位置：\(cf.section) · \(cf.localDevice) ↔ \(cf.remoteDevice)",
                         "Overlap: \(cf.section) · \(cf.localDevice) ↔ \(cf.remoteDevice)"))
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(t("解决", "Resolve")).font(.caption.weight(.semibold)).foregroundStyle(.blue)
              }
            }
            .accessibilityIdentifier("relay.conflict.\(cf.noteId)")
          }
        } header: {
          Text(t("\(meshConflicts.count) 篇笔记存在并行分支", "\(meshConflicts.count) note conflict(s)"))
        } footer: {
          Text(t("两端附件已自动取并集保护（0 项丢失），点击条目选择要保留的版本。",
                 "Attachments from both sides are union-protected (0 lost). Tap a note to choose a version."))
        }
      }
      if relay.groupBusy {
        Section {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(t("正在后台同步设备组状态，页面可继续浏览…", "Updating device group in background; browsing remains interactive…"))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section {
        if !relay.groupFresh {
          Button(t("刷新成员名单", "Refresh members")) { Task { await relay.refreshGroup() } }
            .disabled(relay.groupBusy)
        }
        ForEach(relay.groupMembers) { member in
          Button { memberTarget = member } label: { memberRow(member) }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("relay.member")
        }
        if relay.groupManager {
          Button { inviting = true } label: {
            VStack(alignment: .leading, spacing: 2) {
              Label(t("邀请设备", "Invite device"), systemImage: "qrcode")
              Text(t("二维码与邀请链接 · 10 分钟内有效，只能使用一次", "QR code and link · valid for 10 minutes, one use"))
                .font(.caption).foregroundStyle(.secondary)
            }
          }.disabled(relay.groupBusy).accessibilityIdentifier("relay.invite")
        }
      } header: {
        Text(t("设备组「\(groupTitle)」", "Device group “\(groupTitle)”"))
      } footer: {
        Text((relay.groupManager
          ? t("新设备扫码加入后立即开始双向同步，无需再确认。", "A new device starts syncing both ways as soon as it scans the invitation.")
          : t("请在管理设备上邀请新设备。", "Invite new devices from a managing device."))
          + t("邀请设备、移除成员和解散需在管理设备上进行；任一成员都可以重命名本机或退出。",
            " Inviting, removing members and disbanding happen on a managing device; any member can rename this device or leave."))
      }
      if !relay.automaticGroupJoin && !relay.applicantName.isEmpty {
        // Manual approval remains for invitations created without automatic admission.
        Section(t("加入申请", "Join request")) {
          LabeledContent(t("申请设备", "Applicant"), value: relay.applicantName)
          Text(relay.groupCode).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
          Toggle(t("同时授予设备组管理权限", "Grant group management"), isOn: $grantManager)
          Button(t("两端配对码一致，批准加入", "Codes match, approve")) { Task { await relay.approveGroupRequest(manager: grantManager) } }
        }
      }
      Section {
        NavigationLink {
          Form {
            Section(t("中继地址", "Relay address")) {
              Text(relay.config.endpoint).font(.callout.monospaced()).textSelection(.enabled)
            }
            Section { MobileRelayPasswordSettings(relay: relay, t: t) }
          }.navigationTitle(t("连接设置", "Connection"))
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(t("连接设置", "Connection"))
            Text(t("中继地址来自创建或邀请；可更新本机保存的中继密码", "The relay address comes from creation or the invitation; you can update the saved relay password"))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        NavigationLink {
          peerLibraries
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(t("对等库与家庭库", "Peer & family libraries"))
            Text(t("独立于个人设备组；成员与角色由各库单独管理", "Separate from your device group; each library manages its own members and roles"))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section(t("危险操作", "Danger zone")) {
        Button(role: .destructive) { exit = .leave } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(t("退出设备组", "Leave device group"))
            Text(t("本地资料保留；同步日志加密归档并更新设备标识", "Local data stays; the sync log is archived encrypted and the device ID changes"))
              .font(.caption).foregroundStyle(.secondary)
          }
        }.disabled(relay.groupBusy).accessibilityIdentifier("relay.leave")
        if relay.groupManager {
          Button(role: .destructive) { exit = .disband } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(t("解散设备组", "Disband device group"))
              Text(t("本机先退出，再通知服务器解散；各设备资料不会被远程删除", "This device leaves first, then asks the server to disband; data on other devices is not erased"))
                .font(.caption).foregroundStyle(.secondary)
            }
          }.disabled(relay.groupBusy).accessibilityIdentifier("relay.disband")
        }
      }
      if let failure = relay.failure { Section { Text(localized(failure)).foregroundStyle(.red) } }
    }
    .refreshable {
      await relay.refreshGroup()
      await loadMeshConflicts()
    }
    .task { await loadMeshConflicts() }
    .confirmationDialog(
      resolvingConflict.map { t("解决「\($0.title.isEmpty ? "未命名笔记" : $0.title)」并行分支", "Resolve “\($0.title.isEmpty ? "Untitled note" : $0.title)”") } ?? "",
      isPresented: Binding(get: { resolvingConflict != nil }, set: { if !$0 { resolvingConflict = nil } }),
      titleVisibility: .visible
    ) {
      if let cf = resolvingConflict {
        Button(t("保留本机版本", "Keep local version")) {
          resolvingConflict = nil
          Task { await resolveMeshConflict(cf, resolution: "keep-local") }
        }
        Button(t("采用远端版本", "Use remote version")) {
          resolvingConflict = nil
          Task { await resolveMeshConflict(cf, resolution: "keep-remote") }
        }
        Button(t("保留自动合并结果", "Keep auto-merged")) {
          resolvingConflict = nil
          Task { await resolveMeshConflict(cf, resolution: "keep-merged") }
        }
        Button(t("取消", "Cancel"), role: .cancel) { resolvingConflict = nil }
      }
    } message: {
      if let cf = resolvingConflict {
        Text(t("冲突位置：\(cf.section)（\(cf.localDevice) ↔ \(cf.remoteDevice)）。被替换的版本仍保留在 30 天条目历史中。",
               "Overlap at \(cf.section) (\(cf.localDevice) ↔ \(cf.remoteDevice)). Replaced versions remain in 30-day history."))
      }
    }
    .confirmationDialog(memberTarget?.name ?? "", isPresented: Binding(get: { memberTarget != nil }, set: { if !$0 { memberTarget = nil } }), titleVisibility: .visible) {
      if let member = memberTarget {
        if relay.groupManager || member.id == relay.config.device {
          Button(t("重命名…", "Rename…")) { newName = member.name; renaming = member }
        }
        if relay.groupManager && member.id != relay.config.device {
          Button(t("移除设备…", "Remove device…"), role: .destructive) { removing = member }
        }
        Button(t("取消", "Cancel"), role: .cancel) {}
      }
    } message: {
      if let member = memberTarget {
        Text(status(member) + (relay.groupManager || member.id == relay.config.device ? "" : t("。移除成员只能在管理设备上进行。", ". Only a managing device can remove members.")))
      }
    }
    .alert(t("重命名设备", "Rename device"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField(t("设备名称", "Device name"), text: $newName)
      Button(t("保存", "Save")) {
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let member = renaming, !value.isEmpty { Task { await relay.renameGroupMember(member.id, name: value) } }
        renaming = nil
      }
      Button(t("取消", "Cancel"), role: .cancel) { renaming = nil }
    } message: {
      Text(t("新名称会同步给组内所有设备。", "The new name syncs to every device in the group."))
    }
    .confirmationDialog(t("移除 \(removing?.name ?? "")？", "Remove \(removing?.name ?? "")?"),
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
      Button(t("移除设备", "Remove device"), role: .destructive) {
        if let member = removing { Task { await relay.removeGroupMember(member.id) } }
        removing = nil
      }
      Button(t("取消", "Cancel"), role: .cancel) { removing = nil }
    } message: {
      Text(t("将撤销其设备组成员资格，对方停止同步。本机资料保留；已同步到该设备的资料无法远程删除。",
        "Its group membership is revoked and it stops syncing. Data on this device stays; data already synced to that device can't be erased remotely."))
    }
    .confirmationDialog(exit == .disband ? t("解散「\(groupTitle)」？", "Disband “\(groupTitle)”?") : t("退出设备组？", "Leave the device group?"),
      isPresented: Binding(get: { exit != nil }, set: { if !$0 { exit = nil } }), titleVisibility: .visible) {
      Button(exit == .disband ? t("解散", "Disband") : t("退出", "Leave"), role: .destructive) {
        let disband = exit == .disband
        exit = nil
        Task { await relay.leaveGroup(disband: disband) }
      }
      Button(t("取消", "Cancel"), role: .cancel) { exit = nil }
    } message: {
      Text(exit == .disband
        ? t("本机先退出，再尝试通知服务器解散设备组；各设备已经保存的资料不会被远程删除。即使通知失败，本机也保持退出。",
          "This device leaves first, then tries to tell the server to disband the group. Data saved on each device is not erased remotely. This device stays out even if the notice fails.")
        : t("确认后立即退出本机接入并保留本地资料，不再同步；同步日志将加密归档，本机设备标识会更新。其他成员继续同步，之后可以重新扫描邀请加入。",
          "This device leaves right away and keeps its local data but stops syncing. The sync log is archived encrypted and the device ID changes. Other members keep syncing; you can scan a new invitation later."))
    }
    .sheet(isPresented: $inviting) { MobileRelayInviteSheet(relay: relay) }
  }

  private var statusCard: some View {
    HStack(alignment: .center, spacing: 12) {
      Circle().fill(relay.connected ? Color.green : relay.connecting ? Color.secondary : Color.orange)
        .frame(width: 10, height: 10)
      VStack(alignment: .leading, spacing: 3) {
        Text(relay.connected ? t("已同步 · 自动双向同步", "Synced · both ways automatically")
          : relay.connecting ? t("正在连接", "Connecting") : t("中继未连接", "Relay not connected"))
          .font(.subheadline.weight(.semibold))
          .accessibilityIdentifier("relay.status.title")
        Text(summary).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("relay.status.detail")
      }
      Spacer(minLength: 8)
      Button { relay.syncNow() } label: {
        Label(t("同步", "Sync"), systemImage: "arrow.triangle.2.circlepath")
      }
      .buttonStyle(.bordered).controlSize(.small).disabled(relay.groupInvalid)
      .accessibilityIdentifier("relay.sync")
    }
    .padding(.vertical, 4)
  }

  private var summary: String {
    var parts = ["「\(groupTitle)」"]
    let online = others.filter(\.online).count
    parts.append(t("\(online) / \(others.count) 台其他设备在线", "\(online) of \(others.count) other devices online"))
    if let last = relay.lastSuccess {
      let formatter = RelativeDateTimeFormatter()
      formatter.locale = Locale(identifier: store.chinese ? "zh_CN" : "en_US")
      parts.append(t("上次同步 ", "Last sync ") + formatter.localizedString(for: last, relativeTo: Date()))
    } else {
      parts.append(t("尚未同步", "Not synced yet"))
    }
    if relay.offline { parts.append(t("修改保留在本机", "changes kept on this device")) }
    return parts.joined(separator: " · ")
  }

  private func status(_ member: VaultRelay.GroupMember) -> String {
    if member.id == relay.config.device { return t("本机", "This device") }
    return member.online ? t("在线", "Online") : t("离线", "Offline")
  }

  private func memberRow(_ member: VaultRelay.GroupMember) -> some View {
    HStack(spacing: 12) {
      Image(systemName: member.id == relay.config.device ? "iphone" : "laptopcomputer.and.iphone")
        .foregroundStyle(.blue).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(member.name + (member.manager ? t(" · 管理", " · Manager") : ""))
        Text(status(member)).font(.caption).foregroundStyle(member.online || member.id == relay.config.device ? Color.secondary : Color.orange)
      }
      Spacer()
      Image(systemName: "ellipsis").foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
  }

  private var peerLibraries: some View {
    ScrollView { RelayPeerLibraryView(relay: relay, t: t).padding() }
      .navigationTitle(t("对等库与家庭库", "Peer & family libraries"))
  }

  private func localized(_ text: String) -> String {
    let parts = text.components(separatedBy: " / ")
    return parts.count == 2 ? t(parts[0], parts[1]) : text
  }

  private func loadMeshConflicts() async {
    guard store.unlocked else { meshConflicts = []; return }
    do {
      let res = try await store.perform(["op": .string("relay-mesh-conflicts")])
      let list = res.object["conflicts"]?.array ?? []
      meshConflicts = list.compactMap { entry in
        let obj = entry.object
        guard let noteId = obj["noteId"]?.string, !noteId.isEmpty else { return nil }
        return MeshNoteConflict(
          noteId: noteId,
          title: obj["title"]?.string ?? "",
          section: obj["section"]?.string ?? "",
          localDevice: obj["localDevice"]?.string ?? "",
          remoteDevice: obj["remoteDevice"]?.string ?? ""
        )
      }
    } catch {
      meshConflicts = []
    }
  }

  private func resolveMeshConflict(_ cf: MeshNoteConflict, resolution: String) async {
    do {
      _ = try await store.perform([
        "op": .string("relay-mesh-resolve-conflict"),
        "noteId": .string(cf.noteId),
        "resolution": .string(resolution),
      ])
      try? await store.refresh()
      await loadMeshConflicts()
    } catch {
      relay.failure = t("冲突解决失败，请稍后重试。", "Failed to resolve conflict. Please try again.")
    }
  }
}

/// Invitation sheet: a one-time QR code and link for a new device of the owner.
struct MobileRelayInviteSheet: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var relay: VaultRelay
  var body: some View {
    let t = store.t
    NavigationStack {
      List {
        Section {
          Text(t("在新设备上扫描即可加入并立即双向同步全部密码库内容，无需再确认。请只交给你自己的设备。",
            "Scan on the new device to join and sync the whole vault both ways right away. Share it only with your own devices."))
            .font(.subheadline).foregroundStyle(.secondary)
        }
        Section {
          if relay.groupInvite.isEmpty {
            HStack { Spacer(); ProgressView(t("正在生成邀请…", "Creating invitation…")); Spacer() }.padding(.vertical, 40)
          } else {
            HStack { Spacer(); RelayQRCode(text: relay.groupInvite); Spacer() }
              .accessibilityIdentifier("relay.invite.qr")
            Text(t("10 分钟内有效，只能使用一次", "Valid for 10 minutes, one use")).font(.caption)
              .frame(maxWidth: .infinity)
            if relay.automaticGroupJoin {
              Button { store.copy(relay.groupInvite) } label: {
                Label(t("复制邀请链接", "Copy invitation link"), systemImage: "doc.on.doc")
              }
            }
          }
        } footer: {
          Text(t("邀请链接包含中继地址与中继访问密码，加入方无需另行填写。", "The link includes the relay address and access password, so the new device fills in nothing."))
        }
      }
      .navigationTitle(t("邀请设备", "Invite device")).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(t("取消邀请", "Cancel invitation")) {
            Task { await relay.cancelGroupInvitation() }
            dismiss()
          }.disabled(relay.groupInvite.isEmpty)
        }
        ToolbarItem(placement: .confirmationAction) { Button(t("完成", "Done")) { dismiss() } }
      }
      .task {
        if relay.groupInvite.isEmpty { await relay.inviteToGroup(automatic: relay.config.peerLibrary == nil) }
      }
    }
    .presentationDetents([.large])
  }
}
