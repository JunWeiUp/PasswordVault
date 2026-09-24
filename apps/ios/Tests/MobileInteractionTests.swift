import XCTest

@testable import PasswordVault

@MainActor
final class MobileInteractionTests: XCTestCase {
  func testCancelInvalidatesFillAndCannotCancelNextRequest() async {
    let requests = CredentialRequestLifetime()
    let requestA = requests.advance()
    let cancellationA = requests.advance()
    XCTAssertFalse(requests.isCurrent(requestA), "Cancel immediately invalidates an awaiting fill")
    let requestB = requests.advance()
    await Task.yield()
    XCTAssertFalse(requests.isCurrent(requestA))
    XCTAssertFalse(requests.isCurrent(cancellationA), "Old cleanup must not cancel request B")
    XCTAssertTrue(requests.isCurrent(requestB))
  }

  func testTypingExtendsIdleButBackgroundReadsDoNot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var time = Date()
    let store = MobileVaultStore(directory: directory, now: { time })
    await store.start()
    await store.authenticate("Synthetic idle test 123!", create: true)
    await store.saveSettings(["autoLockMinutes": .number(1)])
    for _ in 0..<4 {
      time = time.addingTimeInterval(40)
      store.activity()
      store.checkIdle()
      XCTAssertTrue(store.unlocked, "Continuous editing must not lock")
    }
    time = time.addingTimeInterval(59)
    _ = try await store.perform(["op": .string("status")])
    store.checkIdle()
    XCTAssertTrue(store.unlocked)
    time = time.addingTimeInterval(2)
    store.checkIdle()
    XCTAssertFalse(store.unlocked, "Background reads must not extend the idle deadline")
    await store.close()
    try FileManager.default.removeItem(at: directory)
  }
}
