import AppKit
import Darwin
import Foundation

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

signal(SIGPIPE, SIG_IGN)

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let application = executable.deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()
let identityURL = application.appendingPathComponent("Contents/Resources/BrowserIdentity.json")
guard let identityData = try? Data(contentsOf: identityURL),
  let identity = try? JSONSerialization.jsonObject(with: identityData) as? [String: String],
  let extensionID = identity["extensionId"], CommandLine.arguments.count >= 2,
  CommandLine.arguments[1] == "chrome-extension://\(extensionID)/"
else {
  respond(["ok": false, "error": "invalid-origin"])
  exit(1)
}

while let prefix = readExactly(.standardInput, 4) {
  let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
  guard length > 0, length <= 65536, let input = readExactly(.standardInput, Int(length)),
    let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
  else {
    respond(["ok": false, "error": "invalid-request"])
    break
  }
  if request["op"] as? String == "open" {
    NSWorkspace.shared.openApplication(
      at: application, configuration: NSWorkspace.OpenConfiguration())
    respond(["ok": true])
    continue
  }
  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  var path = support.appendingPathComponent("PasswordVaultNative/bridge.sock").path
  #if DEBUG
    if let fixture = ProcessInfo.processInfo.environment["PASSWORDVAULT_TEST_SOCKET"] {
      path = fixture
    }
  #endif
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
    respond(["ok": false, "error": "not-running"])
    continue
  }
  let handle = FileHandle(fileDescriptor: socketFD, closeOnDealloc: true)
  let envelope: [String: Any] = ["extensionOrigin": CommandLine.arguments[1], "request": request]
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
      let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
    else { throw NSError(domain: "Bridge", code: 2) }
    respond(object)
  } catch { respond(["ok": false, "error": "unavailable"]) }
  try? handle.close()
}
