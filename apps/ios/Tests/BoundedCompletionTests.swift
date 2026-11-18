import XCTest

@testable import PasswordVault

final class BoundedCompletionTests: XCTestCase {
  func testReturnsTheCallbackValue() async {
    let value = await boundedCompletion(timeout: 2, fallback: false) { done in done(true) }
    XCTAssertTrue(value)
  }

  func testFallsBackWhenTheCallbackNeverArrives() async {
    let started = Date()
    let value = await boundedCompletion(timeout: 0.3, fallback: false) { _ in }
    XCTAssertFalse(value)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }

  func testLateCallbackIsIgnoredAfterTimeout() async throws {
    let value = await boundedCompletion(timeout: 0.2, fallback: false) { done in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { done(true) }
    }
    XCTAssertFalse(value)
    // Let the late callback run; resuming twice would crash the test process.
    try await Task.sleep(nanoseconds: 700_000_000)
  }

  func testOneShotLetsOnlyOneCallerThrough() {
    let gate = OneShot()
    let winners = (0..<100).map { _ in gate.claim() }.filter { $0 }.count
    XCTAssertEqual(winners, 1)
  }
}
