import AppKit
import CryptoKit
import Darwin
import Foundation
import Security
import SwiftUI

enum BridgeFailure: Error { case unavailable, invalidPeer, invalidRequest, pairingLimit }

final class NativeBrowserBridge: @unchecked Sendable {
  static let hostName = "com.securepass.vault.native_v2"
  private weak var store: AppStore?
  private let listener: Int32
  private let socketPath: String
  private let queue = DispatchQueue(label: "PasswordVault.native-browser")
  private let helperURL: URL
  private let extensionID: String
  @MainActor private var pairingInProgress = false

  @MainActor
  init(store: AppStore) throws {
    self.store = store
    helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PasswordVaultBridge")
    extensionID = try Self.identity()
    socketPath = store.directory.appendingPathComponent("bridge.sock").path
    guard socketPath.utf8.count < 104 else { throw BridgeFailure.unavailable }
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw BridgeFailure.unavailable }
    // The directory is private and the core holds an exclusive vault-process lock.
    unlink(socketPath)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { dest in
      dest.copyBytes(from: Array(socketPath.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 8) == 0 else {
      close(listener)
      throw BridgeFailure.unavailable
    }
    queue.async { [weak self] in self?.serve() }
  }

  deinit {
    close(listener)
    unlink(socketPath)
  }

  static func identity() throws -> String {
    guard let url = Bundle.main.url(forResource: "BrowserIdentity", withExtension: "json"),
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        as? [String: String],
      let id = value["extensionId"], id.count == 32
    else { throw BridgeFailure.unavailable }
    return id
  }

  static func installHosts() throws {
    let id = try identity()
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PasswordVaultBridge")
    guard FileManager.default.isExecutableFile(atPath: helper.path) else {
      throw BridgeFailure.unavailable
    }
    let manifest: [String: Any] = [
      "name": hostName, "description": "PasswordVault native vault connection", "path": helper.path,
      "type": "stdio", "allowed_origins": ["chrome-extension://\(id)/"],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    for browser in ["Google/Chrome", "Microsoft Edge", "Microsoft Edge Beta"] {
      let folder = support.appendingPathComponent(browser).appendingPathComponent(
        "NativeMessagingHosts")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let path = folder.appendingPathComponent(hostName + ".json")
      try data.write(to: path, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
  }

  private func serve() {
    while true {
      let client = accept(listener, nil, nil)
      if client < 0 { return }
      var noSignal: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      var timeout = timeval(tv_sec: 15, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      guard validPeer(client) else {
        close(client)
        continue
      }
      guard let data = readMessage(client),
        let request = try? JSONDecoder().decode(JSONValue.self, from: data)
      else {
        close(client)
        continue
      }
      Task { [weak self] in
        guard let self else {
          close(client)
          return
        }
        let response = await self.dispatch(request)
        if let encoded = try? JSONEncoder().encode(response), encoded.count <= 1_000_000 {
          var length = UInt32(encoded.count).littleEndian
          let prefix = withUnsafeBytes(of: &length) { Data($0) }
          if self.writeAll(client, prefix) { _ = self.writeAll(client, encoded) }
        }
        close(client)
      }
    }
  }

  private func validPeer(_ client: Int32) -> Bool {
    var token = audit_token_t()
    var size = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return false }
    let bytes = withUnsafeBytes(of: &token) { Data($0) }
    var guest: SecCode?
    guard
      SecCodeCopyGuestWithAttributes(
        nil, [kSecGuestAttributeAudit as String: bytes] as CFDictionary, [], &guest)
        == errSecSuccess,
      let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess
    else { return false }
    var expected: SecStaticCode?
    guard SecStaticCodeCreateWithPath(helperURL as CFURL, [], &expected) == errSecSuccess,
      let expected, SecStaticCodeCheckValidity(expected, [], nil) == errSecSuccess
    else { return false }
    var guestStatic: SecStaticCode?
    guard SecCodeCopyStaticCode(guest, [], &guestStatic) == errSecSuccess, let guestStatic else {
      return false
    }
    var guestInfo: CFDictionary?
    var expectedInfo: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        guestStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &guestInfo) == errSecSuccess,
      SecCodeCopySigningInformation(
        expected, SecCSFlags(rawValue: kSecCSSigningInformation), &expectedInfo) == errSecSuccess,
      let a = (guestInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
      let b = (expectedInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    else { return false }
    return a == b
  }

  private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
  }

  private func readMessage(_ fd: Int32) -> Data? {
    func readExactly(_ length: Int) -> Data? {
      var bytes = [UInt8](repeating: 0, count: length)
      var offset = 0
      while offset < length {
        let count = bytes.withUnsafeMutableBytes {
          Darwin.read(fd, $0.baseAddress!.advanced(by: offset), length - offset)
        }
        if count <= 0 { return nil }
        offset += count
      }
      return Data(bytes)
    }
    guard let prefix = readExactly(4) else { return nil }
    let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    guard length > 0, length <= 65536 else { return nil }
    return readExactly(Int(length))
  }

  @MainActor
  private func dispatch(_ wrapper: JSONValue) async -> JSONValue {
    func failure(_ code: String) -> JSONValue {
      .object(["ok": .bool(false), "error": .string(code)])
    }
    guard let store else { return failure("unavailable") }
    guard wrapper.object["extensionOrigin"]?.string == "chrome-extension://\(extensionID)/",
      let request = wrapper.object["request"]?.object, request["version"]?.number == 2
    else { return failure("invalid-request") }
    let op = request["op"]?.string ?? ""
    if op == "status" {
      return .object([
        "ok": .bool(true), "unlocked": .bool(store.unlocked), "version": .number(2),
        "paired": .bool(
          store.unlocked
            && Self.isPaired(
              extensionID: extensionID, token: request["token"]?.string ?? "",
              settings: store.settings)
        ),
      ])
    }
    guard store.unlocked else { return failure("locked") }
    if op == "pair" {
      guard !pairingInProgress else { return failure("pairing-busy") }
      pairingInProgress = true
      defer { pairingInProgress = false }
      NSApplication.shared.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = store.t("连接浏览器扩展？", "Connect the browser extension?")
      alert.informativeText = store.t(
        "连接后，Chrome/Edge 扩展可在资料库解锁时请求当前网站的账号。",
        "Once connected, the Chrome/Edge extension can request accounts for the current website while the vault is unlocked."
      )
      alert.addButton(withTitle: store.t("允许连接", "Allow connection"))
      alert.addButton(withTitle: store.t("取消", "Cancel"))
      guard alert.runModal() == .alertFirstButtonReturn, store.unlocked else {
        return failure("cancelled")
      }
      var random = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
        return failure("unavailable")
      }
      let token = Data(random).base64EncodedString()
      do {
        let settings = try Self.addingPairing(
          extensionID: extensionID, previousToken: request["token"]?.string ?? "",
          newToken: token, settings: store.settings)
        _ = try await store.perform(["op": .string("settings"), "settings": .object(settings)])
        store.settings = settings
        return .object(["ok": .bool(true), "token": .string(token)])
      } catch BridgeFailure.pairingLimit {
        return failure("pairing-limit")
      } catch { return failure("unavailable") }
    }
    guard
      Self.isPaired(
        extensionID: extensionID, token: request["token"]?.string ?? "", settings: store.settings)
    else { return failure("unpaired") }
    do {
      var result: JSONValue
      switch op {
      case "matches", "fill":
        let origin = request["origin"]?.string ?? ""
        var query: [String: JSONValue] = ["op": .string(op), "origin": .string(origin)]
        if op == "fill" {
          query["id"] = request["id"]
          query["accountId"] = request["accountId"]
        }
        result = try await store.perform(query)
        if op == "fill" { store.recordBrowserActivity() }
      case "open-entry":
        guard try await store.openBrowserEntry(id: request["id"]?.string ?? "", accountID: request["accountId"]?.string,
          origin: request["origin"]?.string ?? "") else { return failure("invalid-entry") }
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        NSApplication.shared.activate(ignoringOtherApps: true)
        result = .object(["opened": .bool(true)])
      case "save":
        guard let origin = Self.websiteOrigin(request["origin"]?.string ?? ""),
          let host = origin.host, let user = request["username"]?.string,
          let password = request["password"]?.string,
          user.utf8.count <= 4096, password.utf8.count <= 4096
        else { return failure("invalid-request") }
        var item = VaultItem.blank(type: "password", title: host)
        item.username = user
        item.password = password
        item.set("url", origin.absoluteString)
        item.set("updatedAt", ISO8601DateFormatter().string(from: Date()))
        _ = try await store.perform(["op": .string("save"), "item": try .from(item)])
        await store.refresh()
        store.recordBrowserActivity()
        result = .object(["saved": .bool(true)])
      case "lock":
        store.lock()
        result = .object(["locked": .bool(true)])
      default: return failure("unsupported")
      }
      return .object(["ok": .bool(true), "data": result])
    } catch { return failure(store.unlocked ? "failed" : "locked") }
  }

  // Preserve non-default ports so captured credentials retain the same fill boundary.
  static func websiteOrigin(_ value: String) -> URL? {
    guard var parts = URLComponents(string: value),
      let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil,
      parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil
    else { return nil }
    if let port = parts.port, !(1...65535).contains(port) { return nil }
    parts.scheme = scheme
    parts.path = ""
    return parts.url
  }

  private static func pairingTokens(_ value: JSONValue?) -> [String] {
    if case .string(let token) = value { return token.isEmpty ? [] : [token] }
    if case .array(let values) = value { return values.map(\.string).filter { !$0.isEmpty } }
    return []
  }

  static func pairingCount(settings: [String: JSONValue]) -> Int {
    (settings["browserPairings"]?.object ?? [:]).values.reduce(0) { $0 + pairingTokens($1).count }
  }

  static func addingPairing(
    extensionID: String, previousToken: String, newToken: String,
    settings: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard !newToken.isEmpty else { throw BridgeFailure.invalidRequest }
    var pairings = settings["browserPairings"]?.object ?? [:]
    var tokens = pairingTokens(pairings[extensionID]).filter {
      $0 != previousToken && $0 != newToken
    }
    guard tokens.count < 64 else { throw BridgeFailure.pairingLimit }
    tokens.append(newToken)
    pairings[extensionID] = .array(tokens.map(JSONValue.string))
    var updated = settings
    updated["browserPairings"] = .object(pairings)
    return updated
  }

  static func isPaired(extensionID: String, token: String, settings: [String: JSONValue]) -> Bool {
    guard !token.isEmpty else { return false }
    return pairingTokens(settings["browserPairings"]?.object[extensionID]).reduce(false) {
      constantEqual($1, token) || $0
    }
  }

  private static func constantEqual(_ expected: String, _ token: String) -> Bool {
    let left = Array(expected.utf8)
    let right = Array(token.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

struct BrowserSettingsView: View {
  @EnvironmentObject private var store: AppStore
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text(
        store.t("让轻量扩展使用这台 Mac 的资料库。", "Let the lightweight extension use the vault on this Mac.")
      ).foregroundStyle(.secondary)
      Button(store.t("登记 Chrome / Edge 连接", "Register Chrome / Edge connection")) {
        do {
          try NativeBrowserBridge.installHosts()
          store.showToast(
            store.t("已登记，请在扩展中选择「连接 Mac」", "Registered. Choose Connect to Mac in the extension."))
        } catch { store.report(error) }
      }.buttonStyle(VaultButtonStyle(.primary)).tint(Palette.blue).controlSize(.large)
      Text(
        store.t(
          "可同时连接多个浏览器或配置文件。分别在扩展中发起配对，并在 Mac 应用确认。锁定后所有扩展均不能读取密码。",
          "Connect multiple browsers or profiles at once. Pair each extension and confirm in the Mac app. Locking the vault blocks password access for all connections."
        )
      ).fixedSize(horizontal: false, vertical: true)
      Divider()
      Text(store.t("已配对扩展", "Paired extensions")).font(.headline)
      let count = NativeBrowserBridge.pairingCount(settings: store.settings)
      Text(store.t("\(count) 个连接", "\(count) connection(s)")).foregroundStyle(.secondary)
      Button(store.t("撤销全部浏览器连接", "Revoke all browser connections"), role: .destructive) {
        store.settings["browserPairings"] = .object([:])
        Task { await store.saveSettings() }
      }.disabled(count == 0)
    }
  }
}
