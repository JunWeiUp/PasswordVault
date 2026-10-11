import AppKit
import Darwin
import Foundation
import Security

func readExactly(_ file: FileHandle, _ count: Int) -> Data? {
  var data = Data()
  while data.count < count {
    guard let part = try? file.read(upToCount: count - data.count), !part.isEmpty else {
      return nil
    }
    data.append(part)
  }
  return data
}
func respond(_ object: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 1_000_000
  else { return }
  var length = UInt32(data.count).littleEndian
  FileHandle.standardOutput.write(withUnsafeBytes(of: &length) { Data($0) })
  FileHandle.standardOutput.write(data)
}

func openApplication(_ application: URL) -> Bool {
  // sendNativeMessage may close stdin/terminate this helper after its first reply.
  // Keep it alive until Launch Services completes, pumping AppKit's run loop.
  let completed = DispatchSemaphore(value: 0)
  var opened = false
  NSWorkspace.shared.openApplication(
    at: application, configuration: NSWorkspace.OpenConfiguration()
  ) { runningApplication, error in
    opened = runningApplication != nil && error == nil
    completed.signal()
  }
  let deadline = Date().addingTimeInterval(15)
  while completed.wait(timeout: .now()) != .success {
    guard Date() < deadline else { return false }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }
  return opened
}

signal(SIGPIPE, SIG_IGN)
// Legacy login-Keychain APIs do not consistently honor kSecUseAuthenticationUI.
// This is a background helper: never open a system password/ACL dialog.
SecKeychainSetUserInteractionAllowed(false)

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let application = executable.deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()
let desktopInvocation = CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--desktop-unlock"
let identityURL = application.appendingPathComponent("Contents/Resources/BrowserIdentity.json")
guard let identityData = try? Data(contentsOf: identityURL),
  let identity = try? JSONSerialization.jsonObject(with: identityData) as? [String: String],
  let extensionID = identity["extensionId"], CommandLine.arguments.count >= 2,
  (CommandLine.arguments[1] == "chrome-extension://\(extensionID)/" || (desktopInvocation && validDesktopParent(application: application)))
else {
  respond(["ok": false, "error": "invalid-origin"])
  exit(1)
}

while let prefix = readExactly(.standardInput, 4) {
  let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
  guard length > 0, length <= 65536, let input = readExactly(.standardInput, Int(length)),
    var request = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
  else {
    respond(["ok": false, "error": "invalid-request"])
    break
  }
  // Browser input cannot supply native-only authorization material.
  request.removeValue(forKey: "_backgroundGrant")
  guard request["version"] as? Int == 2 else {
    respond(["ok": false, "error": "invalid-request"]); continue
  }
  if desktopInvocation {
    guard request["op"] as? String == "desktop-auto-unlock",
      let nonce = request["nonce"] as? String, UUID(uuidString: nonce) != nil else {
      respond(["ok": false, "error": "invalid-request"]); continue
    }
  } else if ["desktop-auto-unlock", "authorized-matches", "authorized-fill"].contains(request["op"] as? String ?? "") {
    respond(["ok": false, "error": "unsupported"]); continue
  }
  if request["op"] as? String == "open" {
    if openApplication(application) {
      respond(["ok": true])
    } else {
      respond(["ok": false, "error": "native-unavailable"])
    }
    continue
  }
  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  var path = support.appendingPathComponent("PasswordVaultNative/bridge.sock").path
  #if DEBUG
    if let fixture = ProcessInfo.processInfo.environment["PASSWORDVAULT_TEST_SOCKET"] {
      path = fixture
    }
  #endif
  let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
  var op = request["op"] as? String ?? ""
  let syncToken = request["syncToken"] as? String ?? ""
  if op == "configure-sync" || op == "disable-sync" || op == "disable-auto-unlock" {
    do {
      if op == "configure-sync" {
        guard let password = request["password"] as? String, !password.isEmpty,
          password.utf8.count <= 4096 else { throw VaultError.InvalidData }
        try BackgroundSync.configure(directory: directory, extensionID: extensionID,
          token: syncToken, password: password, allowRead: request["allowRead"] as? Bool == true,
          autoUnlock: request["autoUnlock"] as? Bool == true)
      } else if op == "disable-auto-unlock" {
        try BackgroundSync.disableDesktop(directory: directory, extensionID: extensionID, token: syncToken)
      } else {
        try BackgroundSync.revoke(directory: directory, extensionID: extensionID, token: syncToken)
      }
      respond(["ok": true])
    } catch VaultError.Authentication { respond(["ok": false, "error": "authentication"])
    } catch { respond(["ok": false, "error": "sync-keychain"]) }
    continue
  }
  var grant: Data?
  var allowRead = false
  var autoUnlockReady = false
  if desktopInvocation {
    grant = try? BackgroundSync.desktopGrant(directory: directory, extensionID: extensionID)
  } else if ["status", "sync-save", "matches", "fill"].contains(op) {
    if let auth = try? BackgroundSync.authorization(directory: directory, extensionID: extensionID, token: syncToken) {
      grant = auth.grant
      allowRead = auth.allowRead
      if op == "status" {
        autoUnlockReady = auth.autoUnlock
          && BackgroundSync.desktopOwner(directory: directory, extensionID: extensionID, token: syncToken)
      }
    }
  }
  defer { if grant != nil { grant!.resetBytes(in: 0..<grant!.count) } }
  if ["matches", "fill"].contains(op), allowRead {
    op = "authorized-" + op
    request["op"] = op
  }
  if ["sync-save", "authorized-matches", "authorized-fill", "desktop-auto-unlock"].contains(op) {
    guard let grant else { respond(["ok": false, "error": "sync-authorization"]); continue }
    request["_backgroundGrant"] = grant.base64EncodedString()
  }
  guard path.utf8.count < 104 else {
    respond(["ok": false, "error": "unavailable"])
    continue
  }
  let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
  guard socketFD >= 0 else {
    respond(["ok": false, "error": "unavailable"])
    continue
  }
  var noSignal: Int32 = 1
  setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  var timeout = timeval(tv_sec: 45, tv_usec: 0)
  setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connected == 0 else {
    close(socketFD)
    if op == "status" {
      respond(["ok": true, "unlocked": false, "paired": false,
        "syncSupported": true, "syncReady": grant != nil, "readReady": allowRead,
        "autoUnlockReady": autoUnlockReady])
    } else if ["sync-save", "authorized-matches", "authorized-fill"].contains(op), let grant {
      do {
        // Exclusive core lock prevents racing a desktop launch or another helper.
        // The session dies before acknowledging; no resident database/key cache.
        let data: String = try autoreleasepool {
          let session = try VaultSession(directory: directory.path)
          var query = request.filter { $0.key != "_backgroundGrant" }
          if op.hasPrefix("authorized-") { query["op"] = String(op.dropFirst("authorized-".count)) }
          let payload = try JSONSerialization.data(withJSONObject: query)
          let input = String(decoding: payload, as: UTF8.self)
          return op == "sync-save"
            ? try session.backgroundSave(grant: grant, request: input)
            : try session.authorizedBrowserCommand(grant: grant, request: input)
        }
        let result = try JSONSerialization.jsonObject(with: Data(data.utf8))
        respond(["ok": true, "data": result])
      } catch VaultError.InUse { respond(["ok": false, "error": "sync-busy"])
      } catch VaultError.Authentication { respond(["ok": false, "error": "sync-authorization"])
      } catch { respond(["ok": false, "error": "failed"]) }
    } else { respond(["ok": false, "error": "not-running"]) }
    continue
  }
  let handle = FileHandle(fileDescriptor: socketFD, closeOnDealloc: true)
  let envelope: [String: Any] = ["extensionOrigin": "chrome-extension://\(extensionID)/", "request": request]
  guard let payload = try? JSONSerialization.data(withJSONObject: envelope) else {
    respond(["ok": false, "error": "invalid-request"])
    continue
  }
  var payloadLength = UInt32(payload.count).littleEndian
  do {
    try handle.write(contentsOf: withUnsafeBytes(of: &payloadLength) { Data($0) })
    try handle.write(contentsOf: payload)
    guard let prefix = readExactly(handle, 4) else { throw NSError(domain: "Bridge", code: 1) }
    let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    guard length <= 1_000_000, let response = readExactly(handle, Int(length)),
      var object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
    else { throw NSError(domain: "Bridge", code: 2) }
    if op == "status" {
      object["syncSupported"] = true
      object["syncReady"] = grant != nil
      object["readReady"] = allowRead
      object["autoUnlockReady"] = autoUnlockReady
    }
    respond(object)
  } catch { respond(["ok": false, "error": "unavailable"]) }
  try? handle.close()
}
