import XCTest

@testable import PasswordVault

@MainActor
final class CodeSetupTests: XCTestCase {
  func testManualFieldsBuildACodeEntry() throws {
    let item = try XCTUnwrap(CodeSetup.item([
      "title": .string(" GitLab "), "username": .string("alex@example.test"),
      "secret": .string("jbsw y3dp-ehpk 3pxp"), "period": .number(60),
    ]))
    XCTAssertEqual(item.type, "totp")
    XCTAssertEqual(item.title, "GitLab")
    XCTAssertEqual(item.username, "alex@example.test")
    XCTAssertEqual(item.string("secret"), "JBSWY3DPEHPK3PXP")
    XCTAssertEqual(item.number("period"), 60)
    XCTAssertNil(item.fields["digits"], "Unsupported fields are never written")
    XCTAssertEqual(CodeSetup.item(["username": .string("alex"), "secret": .string("A")])?.title, "alex",
      "The account names an entry without an issuer")
    XCTAssertEqual(CodeSetup.item(["secret": .string("A")])?.number("period"), 30)
  }

  func testInvalidManualFieldsAreRejected() {
    XCTAssertNil(CodeSetup.item(["secret": .string("  ")]))
    XCTAssertNil(CodeSetup.item(["secret": .string("A"), "period": .number(0)]))
    XCTAssertNil(CodeSetup.item(["secret": .string("A"), "period": .number(86401)]))
    XCTAssertNil(CodeSetup.item(["secret": .string("A"), "period": .number(30.5)]))
  }

  func testLinkedAccountsShareTheSetupKey() {
    var code = VaultItem.blank(type: "totp", title: "GitHub")
    code.set("secret", "JBSWY3DPEHPK3PXP")
    var account = VaultItem.blank(type: "password", title: "GitHub")
    account.set("secret", "jbsw y3dp ehpk 3pxp")
    var trashed = account
    trashed.fields["id"] = .string("trashed")
    trashed.isDeleted = true
    let other = VaultItem.blank(type: "password", title: "Other")
    XCTAssertEqual(CodeSetup.linkedAccounts(code, in: [code, account, trashed, other]).map(\.id), [account.id])
    code.set("secret", "")
    XCTAssertTrue(CodeSetup.linkedAccounts(code, in: [account]).isEmpty, "Empty keys never link")
  }

  func testAddCodeSavesValidKeysAndKeepsInvalidOnesOut() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MobileVaultStore(directory: directory)
    await store.start()
    await store.authenticate("Synthetic code test 123!", create: true)
    let invalid = await store.addCode(["title": .string("Bad"), "secret": .string("not base32 !!")])
    XCTAssertNotNil(invalid)
    let outOfRange = await store.addCode(["title": .string("Bad"), "secret": .string("JBSWY3DP"), "period": .number(0)])
    XCTAssertNotNil(outOfRange)
    XCTAssertTrue(store.items.isEmpty, "Failed additions save nothing")
    let saved = await store.addCode(["title": .string("Example"), "secret": .string("jbsw y3dp ehpk 3pxp")])
    XCTAssertNil(saved)
    XCTAssertEqual(store.items.filter { $0.type == "totp" }.map(\.title), ["Example"])
    XCTAssertNil(store.error)
    await store.close()
  }
}
