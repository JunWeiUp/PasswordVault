import Foundation

enum DesktopAuthorizationClient {
  // No root key passes through stdout. The verified child returns it only to the
  // app's signed-peer socket, together with a one-use startup challenge.
  static func request(directory: URL, nonce: String) async -> Bool {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PasswordVaultBridge")
    #if !DEBUG
      let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PasswordVaultNative")
      guard directory.standardizedFileURL == expected.standardizedFileURL else { return false }
    #endif
    return await Task.detached {
      do {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--desktop-unlock"]
        #if DEBUG
          var env = ProcessInfo.processInfo.environment
          env["PASSWORDVAULT_TEST_SOCKET"] = directory.appendingPathComponent("bridge.sock").path
          process.environment = env
        #endif
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let bytes = try JSONSerialization.data(withJSONObject: [
          "version": 2, "op": "desktop-auto-unlock", "nonce": nonce,
        ])
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        var length = UInt32(bytes.count).littleEndian
        try input.fileHandleForWriting.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try input.fileHandleForWriting.write(contentsOf: bytes)
        try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard response.count >= 4, response.count <= 4096 else { return false }
        let count = response.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard response.count == 4 + Int(count),
          let result = try JSONSerialization.jsonObject(with: response.dropFirst(4)) as? [String: Any]
        else { return false }
        return result["ok"] as? Bool == true
      } catch { return false }
    }.value
  }
}
