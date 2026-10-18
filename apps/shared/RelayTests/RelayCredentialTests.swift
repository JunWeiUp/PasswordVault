import XCTest
import CommonRelay
@testable import PasswordVault

@MainActor
final class RelayCredentialTests: XCTestCase {
  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Credential loading did not finish")
  }
  private func fixture() async throws -> (URL, RelayTestCore, Data) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("relay-credential-" + UUID().uuidString)
    let core = try RelayTestCore(directory: path)
    _ = try await core.call(["op": .string("create"), "password": .string("fixture")])
    var config = VaultRelay.Config(role: "hub", secret: RelayIdentity.generateSecretKey())
    config.device = "existing-device"; config.group = "existing-group"
    config.token = "FICTIONAL-CREDENTIAL-CANARY"
    return (path, core, try JSONEncoder().encode(config))
  }
  func testMigrationIsUnlockOnlyAndEncryptedFileBypassesLegacyAfterRestart() async throws {
    let (path, core, legacy) = try await fixture()
    defer { try? FileManager.default.removeItem(at: path) }
    var reads = 0
    let relay = VaultRelay(directory: path, role: "hub", call: { try await core.call($0) }, refresh: {},
      credentialReader: { _, interactive in reads += 1; XCTAssertFalse(interactive); return legacy })
    XCTAssertEqual(reads, 0); XCTAssertFalse(relay.credentialsReady)
    relay.setUnlocked(true); try await wait { relay.credentialsReady }
    XCTAssertEqual(reads, 1); XCTAssertEqual(relay.config.device, "existing-device")
    let file = path.appendingPathComponent("vault/relay-private/credentials.v1.enc")
    XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("FICTIONAL-CREDENTIAL-CANARY"))
    relay.setUnlocked(false); XCTAssertTrue(relay.config.token.isEmpty)
    _ = try await core.call(["op": .string("lock")])
    let reloaded = VaultRelay(directory: path, role: "hub", call: { try await core.call($0) }, refresh: {},
      credentialReader: { _, _ in XCTFail("Migrated files must not read Keychain again"); return nil })
    XCTAssertFalse(reloaded.credentialsReady)
    _ = try await core.call(["op": .string("unlock"), "password": .string("fixture")])
    reloaded.setUnlocked(true); try await wait { reloaded.credentialsReady }
    XCTAssertEqual(reloaded.config.device, "existing-device"); XCTAssertEqual(reloaded.config.token, "FICTIONAL-CREDENTIAL-CANARY")
    reloaded.setUnlocked(false)
  }
  func testDeniedOrCancelledLegacyAccessDoesNotCreateReplacementIdentity() async throws {
    let (path, core, legacy) = try await fixture()
    defer { try? FileManager.default.removeItem(at: path) }
    var allow = false, reads: [Bool] = []
    let relay = VaultRelay(directory: path, role: "hub", call: { try await core.call($0) }, refresh: {},
      credentialReader: { _, interactive in reads.append(interactive); guard allow && interactive else { throw RelayError.closed }; return legacy })
    relay.setUnlocked(true); try await wait { relay.credentialAccessBlocked }
    await relay.clearLocalGroup(); await relay.setPaused(false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("vault/relay-private/credentials.v1.enc").path))
    await relay.restoreCredentialAccess(); XCTAssertTrue(relay.credentialAccessBlocked)
    allow = true; await relay.restoreCredentialAccess()
    XCTAssertTrue(relay.credentialsReady); XCTAssertFalse(relay.credentialAccessBlocked)
    XCTAssertEqual(relay.config.device, "existing-device"); XCTAssertEqual(reads, [false, true, true])
    relay.setUnlocked(false)
  }
  func testFailedMigrationWriteRetainsLegacyAndRetriesSameIdentity() async throws {
    let (path, core, legacy) = try await fixture()
    defer { try? FileManager.default.removeItem(at: path) }
    var fail = true
    let relay = VaultRelay(directory: path, role: "hub", call: {
      if fail && $0["op"]?.string == "relay-credentials-write" { throw RelayError.closed }
      return try await core.call($0)
    }, refresh: {}, credentialReader: { _, _ in legacy })
    relay.setUnlocked(true); try await wait { relay.credentialAccessBlocked }
    XCTAssertFalse(relay.credentialsReady)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("vault/relay-private/credentials.v1.enc").path))
    fail = false; await relay.restoreCredentialAccess()
    XCTAssertTrue(relay.credentialsReady); XCTAssertEqual(relay.config.device, "existing-device")
    relay.setUnlocked(false)
  }
  func testCorruptFileNeverFallsBackToLegacyOrOverwritesCiphertext() async throws {
    let (path, core, legacy) = try await fixture()
    defer { try? FileManager.default.removeItem(at: path) }
    let file = path.appendingPathComponent("vault/relay-private/credentials.v1.enc")
    _ = try await core.call(["op": .string("relay-credentials-write"), "data": .string(String(decoding: legacy, as: UTF8.self))])
    let corrupted = Data("corrupt-encrypted-fixture".utf8); try corrupted.write(to: file)
    let relay = VaultRelay(directory: path, role: "hub", call: { try await core.call($0) }, refresh: {},
      credentialReader: { _, _ in XCTFail("Do not fall back on corrupt files"); return legacy })
    relay.setUnlocked(true); try await wait { relay.credentialAccessBlocked }
    await relay.restoreCredentialAccess()
    XCTAssertFalse(relay.credentialsReady); XCTAssertEqual(try Data(contentsOf: file), corrupted)
    relay.setUnlocked(false)
  }
}
