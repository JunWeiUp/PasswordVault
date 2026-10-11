import XCTest
import CryptoKit
import Security
@testable import PasswordVault

@MainActor
final class BackgroundSyncTests: XCTestCase {
  let password = "Synthetic background save 2026!"
  func helper(_ request: [String: Any], directory: URL) async throws -> [String: Any] {
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PasswordVaultBridge")
    let identity = try NativeBrowserBridge.identity()
    let bytes = try JSONSerialization.data(withJSONObject: ["version": 2].merging(request) { _, new in new })
    let operation = request["op"] as? String ?? ""
    let response: Data = try await Task.detached {
      let process = Process()
      // time measures this one helper only, not the app/test runner.
      process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
      process.arguments = ["-l", url.path, "chrome-extension://\(identity)/"]
      var env = ProcessInfo.processInfo.environment
      env["PASSWORDVAULT_TEST_SOCKET"] = directory.appendingPathComponent("bridge.sock").path
      process.environment = env
      let input = Pipe(), output = Pipe(), errors = Pipe()
      process.standardInput = input; process.standardOutput = output; process.standardError = errors
      try process.run()
      let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: watchdog)
      var length = UInt32(bytes.count).littleEndian
      input.fileHandleForWriting.write(withUnsafeBytes(of: &length) { Data($0) })
      input.fileHandleForWriting.write(bytes)
      try input.fileHandleForWriting.close()
      let response = output.fileHandleForReading.readDataToEndOfFile()
      let metrics = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit(); watchdog.cancel()
      guard response.count >= 4 else { throw VaultError.Storage }
      let count = response.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
      guard response.count == 4 + Int(count) else { throw VaultError.Storage }
      // Never print requests, credentials or stdout payloads.
      let memory = metrics.split(separator: "\n").filter { $0.contains(" real ") || $0.contains("maximum resident set size") || $0.contains("peak memory footprint") }
      print("Background helper \(operation) memory: \(memory.joined(separator: "; "))")
      return Data(response.dropFirst(4))
    }.value
    return try JSONSerialization.jsonObject(with: response) as! [String: Any]
  }

  func testQuitAppKeychainSyncReopenAndRevocation() async throws {
    let directory = URL(fileURLWithPath: "/tmp/pv-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var session: VaultSession? = try VaultSession(directory: directory.path)
    _ = try session!.command(request: "{\"op\":\"create\",\"password\":\"\(password)\"}")
    session = nil
    let token = String(repeating: "a", count: 64)
    do {
      let forged = try await helper(["op":"sync-save","syncToken":token,
        "_backgroundGrant":Data(repeating: 0, count: 64).base64EncodedString(),
        "id":"11111111-1111-4111-a111-111111111111","origin":"https://fixture.test",
        "username":"fictional","password":"fictional"], directory: directory)
      XCTAssertEqual(forged["error"] as? String, "sync-authorization")
      let wrong = try await helper(["op":"configure-sync", "syncToken":token, "password":"wrong"], directory: directory)
      XCTAssertEqual(wrong["error"] as? String, "authentication")
      let configured = try await helper(["op":"configure-sync", "syncToken":token, "password":password], directory: directory)
      XCTAssertEqual(configured["ok"] as? Bool, true)
      let identity = directory.standardizedFileURL.path + "\n" + (try NativeBrowserBridge.identity()) + "\n" + token
      let account = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
      let keychainProbe: [String: Any] = [
        kSecClass as String:kSecClassGenericPassword,
        kSecAttrService as String:"com.securepass.vault.browser-background-save.v1",
        kSecAttrAccount as String:account, kSecReturnData as String:true,
        kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
      var unauthorized: CFTypeRef?
      var interaction: DarwinBoolean = true
      SecKeychainGetUserInteractionAllowed(&interaction)
      SecKeychainSetUserInteractionAllowed(false)
      let deniedStatus = SecItemCopyMatching(keychainProbe as CFDictionary, &unauthorized)
      SecKeychainSetUserInteractionAllowed(interaction.boolValue)
      XCTAssertNotEqual(deniedStatus, errSecSuccess,
        "A different executable must not read the helper-owned grant silently")
      let status = try await helper(["op":"status", "syncToken":token], directory: directory)
      XCTAssertEqual(status["syncReady"] as? Bool, true)
      XCTAssertEqual(status["unlocked"] as? Bool, false)
      let record: [String: Any] = ["op":"sync-save", "syncToken":token,
        "id":"11111111-1111-4111-a111-111111111111", "origin":"https://fixture.test",
        "username":"fictional", "password":"Fictional-only-password"]
      for _ in 0..<2 {
        let saved = try await helper(record, directory: directory)
        XCTAssertEqual(saved["ok"] as? Bool, true)
      }
      let reader = try VaultSession(directory: directory.path)
      _ = try reader.command(request: "{\"op\":\"unlock\",\"password\":\"\(password)\"}")
      let doc = try JSONSerialization.jsonObject(with: Data(reader.command(request: "{\"op\":\"list\"}").utf8)) as! [String: Any]
      XCTAssertEqual((doc["items"] as? [[String: Any]])?.count, 1)
      XCTAssertEqual((doc["items"] as? [[String: Any]])?.first?["username"] as? String, "fictional")
      let denied = try await helper(["op":"fill","syncToken":token,"id":"anything","origin":"https://fixture.test"], directory: directory)
      XCTAssertNotEqual(denied["ok"] as? Bool, true)
      try revokeBackgroundGrants(directory: directory.path)
      let revoked = try await helper(record, directory: directory)
      XCTAssertEqual(revoked["error"] as? String, "sync-authorization")
    } catch {
      _ = try? await helper(["op":"disable-sync","syncToken":token], directory: directory)
      throw error
    }
    let disabled = try await helper(["op":"disable-sync","syncToken":token], directory: directory)
    XCTAssertEqual(disabled["ok"] as? Bool, true)
  }

  func testLiveLockedDesktopAcceptsAppendWithoutUnlockingUI() async throws {
    let directory = URL(fileURLWithPath: "/tmp/pv-sync-live-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AppStore(directory: directory)
    await store.start()
    await store.authenticate(password: password, create: true)
    let token = String(repeating: "b", count: 64)
    let configured = try await helper(["op":"configure-sync","syncToken":token,"password":password], directory: directory)
    XCTAssertEqual(configured["ok"] as? Bool,true)
    store.lock(); await store.finishLock()
    let saved = try await helper(["op":"sync-save","syncToken":token,
      "id":"22222222-2222-4222-a222-222222222222","origin":"https://fixture.test",
      "username":"live-fixture","password":"Fictional-only"], directory: directory)
    XCTAssertEqual(saved["ok"] as? Bool,true)
    XCTAssertFalse(store.unlocked)
    XCTAssertTrue(store.items.isEmpty)
    await store.authenticate(password: password, create: false)
    XCTAssertEqual(store.items.first?.username,"live-fixture")
    let disabled = try await helper(["op":"disable-sync","syncToken":token], directory: directory)
    XCTAssertEqual(disabled["ok"] as? Bool,true)
    store.lock(); await store.finishLock()
  }
  func testThousandAccountHelperFootprint() async throws {
    let directory = URL(fileURLWithPath: "/tmp/pv-sync-large-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var session: VaultSession? = try VaultSession(directory: directory.path)
    _ = try session!.command(request: "{\"op\":\"create\",\"password\":\"\(password)\"}")
    let items = (0..<1000).map { index in
      ["id":"fixture-\(index)", "type":"password", "title":"Fictional account \(index)",
       "username":"fixture-\(index)", "password":"Synthetic-only-secret", "url":"https://site\(index).test"]
    }
    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["items":items]), as: UTF8.self)
    let request = try JSONSerialization.data(withJSONObject: ["op":"import","content":content])
    _ = try session!.command(request: String(decoding: request, as: UTF8.self))
    session = nil
    let token = String(repeating: "c", count: 64)
    do {
      let configured = try await helper(["op":"configure-sync","syncToken":token,"password":password], directory: directory)
      XCTAssertEqual(configured["ok"] as? Bool,true)
      let saved = try await helper(["op":"sync-save","syncToken":token,
        "id":"33333333-3333-4333-a333-333333333333","origin":"https://fixture.test",
        "username":"large-fixture","password":"Fictional-only"], directory: directory)
      XCTAssertEqual(saved["ok"] as? Bool,true)
    } catch {
      _ = try? await helper(["op":"disable-sync","syncToken":token], directory: directory)
      throw error
    }
    _ = try await helper(["op":"disable-sync","syncToken":token], directory: directory)
  }

  func testExplicitReadAndStartupUnlockScopesAndManualRelock() async throws {
    let directory = URL(fileURLWithPath: "/tmp/pv-auto-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var session: VaultSession? = try VaultSession(directory: directory.path)
    _ = try session!.command(request: "{\"op\":\"create\",\"password\":\"\(password)\"}")
    _ = try session!.command(request: "{\"op\":\"save\",\"item\":{\"id\":\"fixture\",\"type\":\"password\",\"title\":\"Fixture\",\"url\":\"https://fixture.test\",\"username\":\"fictional\",\"password\":\"Synthetic-secret\"}}")
    session = nil
    let token = String(repeating: "d", count: 64)
    do {
      let old = try await helper(["op":"configure-sync","syncToken":token,"password":password], directory: directory)
      XCTAssertEqual(old["ok"] as? Bool,true)
      let denied = try await helper(["op":"matches","syncToken":token,"origin":"https://fixture.test"], directory: directory)
      XCTAssertEqual(denied["ok"] as? Bool,false, "Save-only authorization must never widen silently")
      let configured = try await helper(["op":"configure-sync","syncToken":token,"password":password,
        "allowRead":true,"autoUnlock":true], directory: directory)
      XCTAssertEqual(configured["ok"] as? Bool,true)
      let status = try await helper(["op":"status","syncToken":token], directory: directory)
      XCTAssertEqual(status["readReady"] as? Bool,true)
      XCTAssertEqual(status["autoUnlockReady"] as? Bool,true)
      let matched = try await helper(["op":"matches","syncToken":token,"origin":"https://fixture.test"], directory: directory)
      XCTAssertEqual((matched["data"] as? [[String: Any]])?.count,1)
      let filled = try await helper(["op":"fill","syncToken":token,"origin":"https://fixture.test","id":"fixture"], directory: directory)
      XCTAssertEqual((filled["data"] as? [String: Any])?["password"] as? String,"Synthetic-secret")
      let foreign = try await helper(["op":"fill","syncToken":token,"origin":"https://foreign.test","id":"fixture"], directory: directory)
      XCTAssertNotEqual(foreign["ok"] as? Bool,true)
      let browserUnlock = try await helper(["op":"desktop-auto-unlock","syncToken":token,"nonce":UUID().uuidString], directory: directory)
      XCTAssertEqual(browserUnlock["error"] as? String,"unsupported")
      let store = AppStore(directory: directory)
      await store.start()
      XCTAssertTrue(store.unlocked, "Explicit startup grant should unlock the desktop without another password")
      XCTAssertEqual(store.items.first?.username,"fictional")
      store.lock(); await store.finishLock()
      await store.start()
      XCTAssertFalse(store.unlocked, "Window reopening must not repeat the startup handshake")
      let replay = await DesktopAuthorizationClient.request(directory: directory, nonce: UUID().uuidString)
      XCTAssertFalse(replay)
      XCTAssertFalse(store.unlocked)
      let stillReadable = try await helper(["op":"matches","syncToken":token,"origin":"https://fixture.test"], directory: directory)
      XCTAssertEqual((stillReadable["data"] as? [[String:Any]])?.count,1)
      XCTAssertFalse(store.unlocked, "Browser reads must preserve the desktop lock")
      let disabled = try await helper(["op":"disable-auto-unlock","syncToken":token], directory: directory)
      XCTAssertEqual(disabled["ok"] as? Bool,true)
      let last = try await helper(["op":"status","syncToken":token], directory: directory)
      XCTAssertEqual(last["autoUnlockReady"] as? Bool,false)
      XCTAssertEqual(last["readReady"] as? Bool,true)
    } catch {
      _ = try? await helper(["op":"disable-sync","syncToken":token], directory: directory)
      throw error
    }
    _ = try await helper(["op":"disable-sync","syncToken":token], directory: directory)
  }

  func testSaveOnlyAndRevokedAuthorizationCannotAutoUnlock() async throws {
    for revoked in [false, true] {
      let directory = URL(fileURLWithPath: "/tmp/pv-auto-deny-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      var session: VaultSession? = try VaultSession(directory: directory.path)
      _ = try session!.command(request: "{\"op\":\"create\",\"password\":\"\(password)\"}")
      session = nil
      let token = String(repeating: "e", count: 64)
      let configured = try await helper(["op":"configure-sync","syncToken":token,"password":password,
        "allowRead":revoked,"autoUnlock":revoked], directory: directory)
      XCTAssertEqual(configured["ok"] as? Bool,true)
      if revoked { try revokeBackgroundGrants(directory: directory.path) }
      let store = AppStore(directory: directory)
      await store.start()
      XCTAssertTrue(store.ready); XCTAssertFalse(store.unlocked)
      XCTAssertNil(store.authenticationError, "Absent/revoked automatic authorization should leave normal password entry usable")
      _ = try await helper(["op":"disable-sync","syncToken":token], directory: directory)
    }
  }

  func testManualLockCancelsAnInFlightStartupUnlock() async throws {
    let directory = URL(fileURLWithPath: "/tmp/pv-auto-race-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var session: VaultSession? = try VaultSession(directory: directory.path)
    let input = try JSONSerialization.data(withJSONObject: ["op":"create","password":password])
    _ = try session!.command(request: String(decoding: input, as: UTF8.self))
    session = nil
    let token = String(repeating: "f", count: 64)
    let configured = try await helper(["op":"configure-sync","syncToken":token,"password":password,
      "allowRead":true,"autoUnlock":true], directory: directory)
    XCTAssertEqual(configured["ok"] as? Bool,true)
    let store = AppStore(directory: directory)
    let startup = Task { await store.start() }
    for _ in 0..<10000 {
      if store.busy { break }
      await Task.yield()
    }
    XCTAssertTrue(store.busy)
    store.lock()
    await startup.value
    await store.finishLock()
    XCTAssertFalse(store.unlocked)
    XCTAssertTrue(store.items.isEmpty)
    _ = try await helper(["op":"disable-sync","syncToken":token], directory: directory)
  }

}
