import XCTest

@testable import PasswordVault

@MainActor
final class MobileOnboardingTests: XCTestCase {
  func testWrongPasswordIsReportedInlineAndClearedOnSuccess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MobileVaultStore(directory: directory)
    await store.start()
    await store.authenticate("Synthetic onboarding 123!", create: true)
    XCTAssertTrue(store.unlocked)
    XCTAssertEqual(store.offerBiometrics, MobileVaultStore.biometricsOfferable, "Offered only when available")
    store.lock()
    XCTAssertFalse(store.offerBiometrics, "Locking ends the first-run offer")

    await store.authenticate("wrong", create: false)
    XCTAssertFalse(store.unlocked)
    XCTAssertNotNil(store.unlockError, "Shown under the field")
    XCTAssertNil(store.error, "No global alert for a wrong password")
    XCTAssertFalse(store.offerBiometrics)

    await store.authenticate("Synthetic onboarding 123!", create: false)
    XCTAssertTrue(store.unlocked)
    XCTAssertNil(store.unlockError)
    XCTAssertFalse(store.offerBiometrics, "Unlocking an existing vault never offers enrollment")
    await store.close()
  }

  func testEmptyNewPasswordStaysAGlobalError() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MobileVaultStore(directory: directory)
    await store.start()
    await store.authenticate("", create: true)
    XCTAssertFalse(store.unlocked)
    XCTAssertNotNil(store.error)
    XCTAssertNil(store.unlockError)
  }
}
