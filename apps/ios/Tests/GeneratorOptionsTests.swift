import XCTest

@testable import PasswordVault

final class GeneratorOptionsTests: XCTestCase {
  func testLengthIsClampedToTheMobileRange() {
    var options = GeneratorOptions()
    options.length = 2
    XCTAssertEqual(options.length, 4)
    options.length = 500
    XCTAssertEqual(options.length, 64)
  }

  func testRequestCarriesEveryRuleAndNeedsOneCharacterType() {
    var options = GeneratorOptions()
    options.length = 32
    options.symbols = false
    XCTAssertEqual(options.request["length"], .number(32))
    XCTAssertEqual(options.request["symbols"], .bool(false))
    XCTAssertEqual(options.request["upper"], .bool(true))
    XCTAssertTrue(options.valid)
    options.upper = false; options.lower = false; options.digits = false
    XCTAssertFalse(options.valid)
  }
}
