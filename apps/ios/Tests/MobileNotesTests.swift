import XCTest

@testable import PasswordVault

final class MobileNotesTests: XCTestCase {
  private func note(_ title: String, updated: String, created: String = "", pinned: Bool = false) -> VaultItem {
    var value = VaultItem.blank(type: "secureNote", title: title)
    value.set("updatedAt", updated)
    if !created.isEmpty { value.set("createdAt", created) }
    value.isPinned = pinned
    return value
  }

  func testPinnedFirstThenChosenOrder() {
    let notes = [
      note("beta", updated: "2026-01-03T00:00:00Z", created: "2025-01-01T00:00:00Z"),
      note("Alpha", updated: "2026-01-01T00:00:00Z", created: "2025-06-01T00:00:00Z"),
      note("gamma", updated: "2026-01-02T00:00:00.500Z", pinned: true),
      note("delta", updated: "2026-01-04T00:00:00+00:00"),
    ]
    XCTAssertEqual(NoteSort.modified.sorted(notes).map(\.title), ["gamma", "delta", "beta", "Alpha"])
    XCTAssertEqual(NoteSort.title.sorted(notes).map(\.title), ["gamma", "Alpha", "beta", "delta"])
    // Without createdAt, a note falls back to its modification date.
    XCTAssertEqual(NoteSort.created.sorted(notes).map(\.title), ["gamma", "delta", "Alpha", "beta"])
  }

  func testStoredSortValuesStayStable() {
    XCTAssertEqual(NoteSort.allCases.map(\.rawValue), ["modified", "title", "created"])
    XCTAssertEqual(NoteSort.defaultsKey, "notesSort")
    XCTAssertNil(NoteSort.parse("not a date"))
  }
}
