import SwiftUI

/// The SSH command for a device entry, for copying or handing to a terminal app through the
/// share sheet. It carries only user, host and port — never a password, private key or other
/// secret — and the phone never runs it. Mirrors Android's `DeviceCommand.kt`.
enum DeviceCommand {
  private static let safeHost = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:\\[\\]-]{1,253}$")
  private static let safeUser = try! NSRegularExpression(pattern: "^[A-Za-z0-9._@-]{1,64}$")

  private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
    expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
  }

  /// Reads a port stored as a number or numeric string; anything else is nil.
  static func port(_ value: JSONValue?) -> Int? {
    switch value {
    case .number(let number) where number.isFinite && abs(number) < 1e9: return Int(number)
    case .string(let text): return Int(text.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  /// `ssh [-p PORT] [USER@]HOST`, or nil when the entry has no usable host.
  static func ssh(_ device: [String: JSONValue]?) -> String? {
    guard let device, DeviceRecord.readable(device) else { return nil }
    let host = (device["host"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard matches(safeHost, host), !host.hasPrefix("-") else { return nil }
    let user = (device["username"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let target = !user.isEmpty && matches(safeUser, user) && !user.hasPrefix("-") ? "\(user)@\(host)" : host
    let port = device["port"] == nil ? 22 : (port(device["port"]) ?? 22)
    return (1...65535).contains(port) && port != 22 ? "ssh -p \(port) \(target)" : "ssh \(target)"
  }
}

/// Read-only access to the `device` object of a format-7 device entry. Only version 1 is read.
enum DeviceRecord {
  static func readable(_ device: [String: JSONValue]?) -> Bool {
    guard let device, case .number(let version)? = device["version"] else { return false }
    return version == 1
  }
  static func portText(_ value: JSONValue?) -> String {
    switch value {
    case .number: return DeviceCommand.port(value).map(String.init) ?? ""
    case .string(let text): return text
    default: return ""
    }
  }
}

/// Settings › Library › Devices & services: device entries, view and copy only.
struct MobileDeviceList: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var search = ""
  private var devices: [VaultItem] {
    store.items.filter { item in
      guard item.type == "device", !item.isDeleted else { return false }
      guard !search.isEmpty else { return true }
      let device = item.fields["device"]?.object ?? [:]
      return [item.title, device["host"]?.string ?? "", device["username"]?.string ?? ""]
        .joined(separator: " ").localizedCaseInsensitiveContains(search)
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }
  var body: some View {
    List {
      Section {
        if devices.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(search.isEmpty ? store.t("还没有设备", "No devices yet") : store.t("没有匹配的设备", "No matching devices"))
              .font(.headline)
            Text(store.t("在桌面端添加设备后，会同步到这里。", "Add devices on desktop; they sync here."))
              .foregroundStyle(.secondary)
          }.padding(.vertical, 16)
        }
        ForEach(devices) { item in
          NavigationLink { MobileDeviceDetail(id: item.id) } label: {
            let device = item.fields["device"]?.object
            VStack(alignment: .leading, spacing: 4) {
              Text(item.title.isEmpty ? store.t("未命名", "Untitled") : item.title).font(.headline).lineLimit(1)
              Text(DeviceRecord.readable(device)
                ? [device?["username"]?.string ?? "", device?["host"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: "@")
                : store.t("格式不受支持", "Unsupported format"))
                .font(.subheadline.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.vertical, 4)
          }
        }
      } footer: {
        Text(store.t("手机端只读查看与复制，不连接设备，也不执行命令或脚本。", "View and copy only. This phone does not connect to devices or run commands or scripts."))
      }
    }
    .navigationTitle(store.t("设备与服务", "Devices & services"))
    .searchable(text: $search, prompt: store.t("搜索", "Search"))
  }
}

/// Read-only device page mirroring Android's `DeviceDetail.kt`.
struct MobileDeviceDetail: View {
  @EnvironmentObject private var store: MobileVaultStore
  let id: String
  @State private var revealing = Set<String>()
  @State private var files: [String: String] = [:]
  @State private var reading: String?
  @State private var failedFile: String?
  private var item: VaultItem? { store.items.first { $0.id == id } }

  var body: some View {
    Group {
      if let item {
        let device = item.fields["device"]?.object
        List {
          Section {
            Text(item.title.isEmpty ? store.t("未命名", "Untitled") : item.title).font(.title2.bold())
            if item.isDeleted {
              Text(store.t("此条目在回收站中。", "This entry is in Trash.")).foregroundStyle(.red)
            }
          } footer: {
            Text(store.t("只读查看与复制；手机不会连接设备或执行命令。", "View and copy only. This phone does not connect to devices or execute commands."))
          }
          if let device, DeviceRecord.readable(device) {
            content(item, device)
          } else {
            Section {
              Label(store.t("无法读取此设备格式，请在桌面端检查。", "Cannot read this device format. Check it on desktop."), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).accessibilityIdentifier("device.unsupported")
            }
          }
        }
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
      } else {
        Text(store.t("此条目已移除", "Entry removed"))
      }
    }
    .onDisappear { revealing.removeAll(); files.removeAll() }
  }

  @ViewBuilder private func content(_ item: VaultItem, _ device: [String: JSONValue]) -> some View {
    Section(store.t("连接", "Connection")) {
      field(store.t("主机", "Host"), device["host"]?.string ?? "", key: "host", monospace: true)
      field(store.t("端口", "Port"), DeviceRecord.portText(device["port"]), key: "port", monospace: true)
      field(store.t("用户名", "Username"), device["username"]?.string ?? "", key: "username")
      let method = device["authMethod"]?.string ?? ""
      if !method.isEmpty {
        LabeledContent(store.t("认证方式", "Authentication"), value: authLabel(method))
      }
      field(store.t("密码", "Password"), device["password"]?.string ?? "", key: "password", secret: true)
      field(store.t("私钥", "Private key"), device["privateKey"]?.string ?? "", key: "privateKey", secret: true, monospace: true)
      let aliases = (device["aliases"]?.array ?? []).map(\.string).filter { !$0.isEmpty }
      field(store.t("别名", "Aliases"), aliases.joined(separator: "\n"), key: "aliases")
    }
    if let command = DeviceCommand.ssh(device) {
      Section {
        field(store.t("连接命令", "Connection command"), command, key: "command", monospace: true)
        ShareLink(item: command) {
          Label(store.t("发送到终端应用…", "Send to a terminal app…"), systemImage: "terminal")
        }.accessibilityIdentifier("device.share")
      } header: {
        Text(store.t("外部终端", "External terminal"))
      } footer: {
        Text(store.t(
          "命令只包含用户名、主机和端口，不含密码或私钥；在 Termius、Blink 等终端应用中由你确认执行，本机不会执行。",
          "The command holds only the user, host and port, never a password or key. You run it in a terminal app such as Termius or Blink; this phone does not run it."))
      }
    }
    ForEach(Array((device["services"]?.array ?? []).enumerated()), id: \.offset) { index, value in
      let service = value.object
      let name = service["name"]?.string ?? ""
      Section(name.isEmpty ? store.t("服务 \(index + 1)", "Service \(index + 1)") : name) {
        LabeledContent(store.t("类型", "Type"), value: serviceKind(service["kind"]?.string ?? ""))
        field(store.t("远程端口", "Remote port"), DeviceRecord.portText(service["remotePort"]), key: "service-\(index)-remote")
        field(store.t("本地端口", "Local port"), DeviceRecord.portText(service["localPort"]), key: "service-\(index)-local")
        field(store.t("路径", "Path"), service["path"]?.string ?? "", key: "service-\(index)-path", monospace: true)
      }
    }
    let commands = device["commands"]?.array ?? []
    let attachments = device["files"]?.array ?? []
    Section(store.t("资料文件 · \(commands.count + attachments.count)", "Documents · \(commands.count + attachments.count)")) {
      if commands.isEmpty && attachments.isEmpty {
        Text(store.t("尚无设备文档", "No device documents")).foregroundStyle(.secondary)
      }
      ForEach(Array(commands.enumerated()), id: \.offset) { index, value in
        let document = value.object
        let title = document["title"]?.string ?? ""
        NavigationLink {
          MobileDeviceDocument(
            title: title.isEmpty ? store.t("资料 \(index + 1)", "Document \(index + 1)") : title,
            text: document["text"]?.string ?? "")
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(title.isEmpty ? store.t("资料 \(index + 1)", "Document \(index + 1)") : title)
            Text(store.t("文档 · 只读查看与复制", "Document · view and copy only")).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      ForEach(Array(attachments.enumerated()), id: \.offset) { index, value in
        fileRow(item, value.object, index: index)
      }
    }
    field(store.t("设备备注", "Device notes"), device["notes"]?.string ?? "", key: "deviceNotes", secret: true, section: store.t("说明", "Description"))
    field(store.t("备注", "Notes"), item.note, key: "note", secret: true, section: store.t("备注", "Notes"))
  }

  private func serviceKind(_ kind: String) -> String {
    switch kind {
    case "ssh": return "SSH"
    case "vnc": return "VNC"
    case "browser": return store.t("网页", "Web")
    case "custom": return store.t("自定义", "Custom")
    default: return kind
    }
  }

  private func authLabel(_ method: String) -> String {
    switch method {
    case "password": return store.t("密码", "Password")
    case "key": return store.t("私钥", "Private key")
    case "agent": return store.t("SSH Agent（桌面端）", "SSH agent (desktop)")
    default: return method
    }
  }

  @ViewBuilder private func fileRow(_ item: VaultItem, _ file: [String: JSONValue], index: Int) -> some View {
    let attachment = file["attachmentId"]?.string ?? ""
    let name = file["name"]?.string ?? ""
    VStack(alignment: .leading, spacing: 8) {
      Label(name.isEmpty ? store.t("设备文档", "Device document") : name, systemImage: "doc.text")
      let size = file["size"].map { "\(Int($0.number)) B" } ?? ""
      let meta = [file["mime"]?.string ?? "", size].filter { !$0.isEmpty }.joined(separator: " · ")
      if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary) }
      if let text = files[attachment] {
        Text(text).font(.callout.monospaced()).textSelection(.enabled)
        HStack {
          Button(store.t("复制", "Copy")) { store.copy(text) }
          Button(store.t("关闭文档", "Close document")) { files[attachment] = nil }
        }.buttonStyle(.bordered)
      } else if item.isDeleted {
        Text(store.t("恢复条目后可读取文档。", "Restore the entry to read its documents.")).font(.caption)
      } else {
        Button(reading == attachment ? store.t("正在读取…", "Reading…") : store.t("读取加密文档", "Read encrypted document")) {
          read(item.id, attachment)
        }
        .buttonStyle(.bordered).disabled(reading != nil || attachment.isEmpty)
      }
      if failedFile == attachment {
        Text(store.t("无法读取文档，请确认附件已同步且格式受支持后重试。", "Could not read document. Check that the attachment has synced and its format is supported, then retry."))
          .font(.caption).foregroundStyle(.red)
      }
    }.padding(.vertical, 4)
  }

  private func read(_ owner: String, _ attachment: String) {
    reading = attachment
    failedFile = nil
    Task {
      defer { reading = nil }
      do {
        let result = try await store.perform(CoreRequest.devicesFileRead(id: owner, attachmentId: attachment))
        guard case .string(let text)? = result.object["text"] else { throw VaultError.InvalidData }
        files[attachment] = text
      } catch { failedFile = attachment }
    }
  }

  @ViewBuilder private func field(
    _ label: String, _ value: String, key: String, secret: Bool = false, monospace: Bool = false,
    section: String? = nil
  ) -> some View {
    if !value.isEmpty {
      if let section {
        Section(section) { fieldRow(label, value, key: key, secret: secret, monospace: monospace) }
      } else {
        fieldRow(label, value, key: key, secret: secret, monospace: monospace)
      }
    }
  }

  private func fieldRow(_ label: String, _ value: String, key: String, secret: Bool, monospace: Bool) -> some View {
    let shown = !secret || revealing.contains(key)
    return VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(shown ? value : "••••••••••••")
        .font(monospace || !shown ? .body.monospaced() : .body)
        .textSelection(.enabled)
        .accessibilityIdentifier("device.field.\(key)")
      HStack {
        if secret {
          Button(revealing.contains(key) ? store.t("隐藏", "Hide") : store.t("显示", "Show")) {
            if revealing.contains(key) { revealing.remove(key) } else { revealing.insert(key) }
          }
        }
        Button(store.t("复制", "Copy")) { store.copy(value) }
      }.buttonStyle(.bordered)
    }.padding(.vertical, 2)
  }
}

/// A device document (stored command text) shown hidden by default; view and copy only.
struct MobileDeviceDocument: View {
  @EnvironmentObject private var store: MobileVaultStore
  let title: String
  let text: String
  @State private var shown = false
  var body: some View {
    List {
      Section {
        Text(shown ? text : "••••••••••••").font(.body.monospaced()).textSelection(.enabled)
        HStack {
          Button(shown ? store.t("隐藏", "Hide") : store.t("显示", "Show")) { shown.toggle() }
          Button(store.t("复制", "Copy")) { store.copy(text) }
        }.buttonStyle(.bordered)
      } footer: {
        Text(store.t("手机上不执行命令或脚本。", "Commands and scripts are not executed on this phone."))
      }
    }
    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    .onDisappear { shown = false }
  }
}
