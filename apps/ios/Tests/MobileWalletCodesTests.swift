import XCTest

@testable import PasswordVault

final class MobileWalletCodesTests: XCTestCase {
  func testWalletsGroupCardsIdentitiesAndCryptoWithoutChangingStoredTypes() {
    XCTAssertEqual(Destination.wallets.listedTypes, ["crypto", "creditCard", "identity"])
    XCTAssertEqual(Destination.passwords.listedTypes, ["password"])
    XCTAssertEqual(Destination.codes.listedTypes, ["totp"])
    XCTAssertTrue(Destination.trash.listedTypes.isEmpty)
    // Stored identifiers stay stable for existing navigation state and vault data.
    XCTAssertEqual(Destination.wallets.rawValue, "wallets")
    XCTAssertEqual(Destination.wallets.itemType, "crypto")
  }

  func testLibraryViewsListEveryLiveTypeWithoutChangingExistingDestinations() {
    let types: Set<String> = ["secureNote", "password", "totp", "crypto", "creditCard", "identity"]
    XCTAssertEqual(Destination.all.listedTypes, types)
    XCTAssertEqual(Destination.favorites.listedTypes, types)
    XCTAssertFalse(Destination.all.listedTypes.contains("device"))
    XCTAssertNil(Destination.all.itemType)
    XCTAssertEqual(Destination(rawValue: "notes"), .notes)
    XCTAssertEqual(Destination(rawValue: "trash"), .trash)
  }

  func testCodesAreGroupedForReading() {
    XCTAssertEqual(MobileCodeRow.grouped("123456"), "123 456")
    XCTAssertEqual(MobileCodeRow.grouped("12345678"), "1234 5678")
    XCTAssertEqual(MobileCodeRow.grouped("12345"), "12345")
    XCTAssertEqual(MobileCodeRow.grouped(""), "——— ———")
  }
}

final class MobileNextCodeTests: XCTestCase {
  func testNextWindowStartsAtTheFollowingStep() {
    let window = MobileCodeRow.nextWindow(now: 1_000_000_010.4, period: 30)
    XCTAssertEqual(window.time, 1_000_000_020)
    XCTAssertEqual(window.remaining, 10)
    let boundary = MobileCodeRow.nextWindow(now: 60, period: 30)
    XCTAssertEqual(boundary.time, 90, "At a boundary the next code is a full period away")
    XCTAssertEqual(boundary.remaining, 30)
    XCTAssertEqual(MobileCodeRow.nextWindow(now: 5, period: 0).time, 6, "Invalid periods fall back to 1 s")
  }
}
