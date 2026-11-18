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

final class PassphraseOptionsTests: XCTestCase {
  func testCharacterRequestHasNoMode() {
    XCTAssertNil(GeneratorOptions().request["mode"])
  }

  func testPassphraseRequestCarriesWordOptions() {
    var options = GeneratorOptions()
    options.mode = .passphrase
    XCTAssertEqual(options.request["mode"], .string("passphrase"))
    XCTAssertEqual(options.request["words"], .number(5))
    XCTAssertEqual(options.request["separator"], .string("-"))
    XCTAssertEqual(options.request["capitalize"], .bool(false))
    XCTAssertEqual(options.request["number"], .bool(false))
    XCTAssertNil(options.request["length"])
    options.words = 8; options.separator = " "; options.capitalize = true; options.number = true
    XCTAssertEqual(options.request["words"], .number(8))
    XCTAssertEqual(options.request["separator"], .string(" "))
    XCTAssertEqual(options.request["capitalize"], .bool(true))
    XCTAssertEqual(options.request["number"], .bool(true))
    // Character classes do not apply to word mode.
    options.upper = false; options.lower = false; options.digits = false; options.symbols = false
    XCTAssertTrue(options.valid)
  }

  func testWordCountAndSeparatorFollowTheCoreLimits() {
    var options = GeneratorOptions()
    options.mode = .passphrase
    options.words = 1
    XCTAssertEqual(options.words, 3)
    options.words = 99
    XCTAssertEqual(options.words, 10)
    XCTAssertEqual(GeneratorOptions.separators, ["-", ".", "_", " "])
    options.separator = "/"
    XCTAssertFalse(options.valid)
  }
}
