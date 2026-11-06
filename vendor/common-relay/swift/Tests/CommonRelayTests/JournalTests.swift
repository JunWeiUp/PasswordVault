import XCTest
@testable import CommonRelay
private final class JournalTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000000
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
final class JournalTests: XCTestCase {
    func testRestartRetryExpiryAndCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = JournalTestClock()
        var journal = try RelayJournal(directory: dir, clock: { clock.read() })
        let data = Data("hello".utf8)
        let first = try journal.prepare(scope: "a", id: "id", to: "bob", data: data, ttl: 60) { _ in "cipher" }
        clock.advance(30); journal = try RelayJournal(directory: dir, clock: { clock.read() })
        let retried = try journal.prepare(scope: "a", id: "id", to: "bob", data: data) { _ in XCTFail("re-encrypted retry"); return "wrong" }
        XCTAssertEqual(first.0, retried.0); XCTAssertEqual(first.1, retried.1)
        XCTAssertThrowsError(try journal.prepare(scope: "a", id: "id", to: "bob", data: Data()) { _ in "bad" })
        try journal.acknowledge(scope: "a", sender: "bob", id: "received")
        XCTAssertTrue(try journal.contains(scope: "a", sender: "bob", id: "received"))
        XCTAssertFalse(try journal.contains(scope: "other", sender: "bob", id: "received"))
        clock.advance(30); try journal.cleanup()
        XCTAssertThrowsError(try journal.prepare(scope: "a", id: "id", to: "bob", data: data) { _ in "bad" })
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: file); XCTAssertFalse(text.contains("cipher"))
        }
        clock.advance(7 * 86400); try journal.cleanup()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0)
    }
    func testConcurrentAcknowledgmentsShareOneJournal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RelayJournal(directory: dir)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do { try journal.acknowledge(scope: "a", sender: "b", id: String(index)) }
            catch { XCTFail("Concurrent journal write failed: \(error)") }
        }
        for index in 0..<32 { XCTAssertTrue(try journal.contains(scope: "a", sender: "b", id: String(index))) }
    }
    func testReceivedDropsCipherAndKeepsResult() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RelayJournal(directory: dir)
        _ = try journal.prepare(scope: "a", id: "id", to: "b", data: Data()) { _ in "cipher" }
        try journal.complete(scope: "a", id: "id")
        XCTAssertNil(try journal.prepare(scope: "a", id: "id", to: "b", data: Data()) { _ in "wrong" }.0)
    }
}
