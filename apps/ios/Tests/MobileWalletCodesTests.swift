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

  func testCodesAreGroupedForReading() {
    XCTAssertEqual(MobileCodeRow.grouped("123456"), "123 456")
    XCTAssertEqual(MobileCodeRow.grouped("12345678"), "1234 5678")
    XCTAssertEqual(MobileCodeRow.grouped("12345"), "12345")
    XCTAssertEqual(MobileCodeRow.grouped(""), "——— ———")
  }
}
