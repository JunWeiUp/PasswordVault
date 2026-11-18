import XCTest

@testable import PasswordVault

final class MobileSettingsTests: XCTestCase {
  func testStartTabFallsBackToNotes() {
    XCTAssertEqual(StartTab.resolve("codes"), .codes)
    XCTAssertEqual(StartTab.resolve("wallets"), .wallets)
    XCTAssertEqual(StartTab.resolve("settings"), .notes, "Only content tabs can open first")
    XCTAssertEqual(StartTab.resolve(nil), .notes)
    XCTAssertEqual(StartTab.key, "startTab")
  }

  func testClipboardDurationDefaultsTo30Seconds() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    XCTAssertEqual(ClipboardClear.seconds(defaults), 30)
    defaults.set(15, forKey: ClipboardClear.key)
    XCTAssertEqual(ClipboardClear.seconds(defaults), 15)
    defaults.set(0, forKey: ClipboardClear.key)
    XCTAssertEqual(ClipboardClear.seconds(defaults), 0)
    defaults.set(7, forKey: ClipboardClear.key)
    XCTAssertEqual(ClipboardClear.seconds(defaults), 30, "Unknown values fall back to the default")
    let t: (String, String) -> String = { zh, _ in zh }
    XCTAssertEqual(ClipboardClear.notice(60, t: t), "已复制，1 分钟后清除")
    XCTAssertEqual(ClipboardClear.notice(0, t: t), "已复制，锁定时清除")
  }

  func testRecoverySpotCheckNeedsTwoCorrectGroups() {
    let key = "aaaa0001-bbbb0002-cccc0003-dddd0004-eeee0005"
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<20 {
      let check = RecoverySpotCheck(key: key, using: &generator)
      XCTAssertEqual(check.indices.count, 2)
      XCTAssertNotEqual(check.indices[0], check.indices[1])
      let right = check.indices.map { check.groups[$0] }
      XCTAssertTrue(check.matches(right))
      XCTAssertTrue(check.matches(right.map { " " + $0.uppercased() }), "Case and spaces are ignored")
      XCTAssertFalse(check.matches([right[0], "wrong"]))
      XCTAssertFalse(check.matches(["", ""]))
    }
    XCTAssertFalse(RecoverySpotCheck(key: "").matches(["", ""]), "An empty key never passes")
  }

  func testAuditFiltersMatchCoreFlags() {
    let results: [JSONValue] = [
      .object(["id": .string("a"), "weak": .bool(true), "reused": .bool(false), "expired": .bool(false)]),
      .object(["id": .string("b"), "weak": .bool(true), "reused": .bool(true), "expired": .bool(false)]),
      .object(["id": .string("c"), "weak": .bool(false), "reused": .bool(false), "expired": .bool(true)]),
    ]
    XCTAssertEqual(AuditFilter.filtered(results, by: .weak).count, 2)
    XCTAssertEqual(AuditFilter.filtered(results, by: .reused).count, 1)
    XCTAssertEqual(AuditFilter.filtered(results, by: .expired).map { $0.object["id"]?.string }, ["c"])
    XCTAssertEqual(AuditFilter.filtered(results, by: nil).count, 3)
  }
}
