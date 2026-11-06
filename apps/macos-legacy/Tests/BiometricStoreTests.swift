import LocalAuthentication
import Security
import XCTest

@testable import PasswordVault

final class BiometricStoreTests: XCTestCase {
  func testDuplicateEnrollmentUpdatesKeyAndPropagatesFailure() throws {
    var updates = 0
    try BiometricStore.finishEnrollment(status: errSecDuplicateItem) {
      updates += 1
      return errSecSuccess
    }
    XCTAssertEqual(updates, 1)
    XCTAssertThrowsError(try BiometricStore.finishEnrollment(status: errSecDuplicateItem) {
      errSecAuthFailed
    })
    XCTAssertThrowsError(try BiometricStore.finishEnrollment(status: errSecMissingEntitlement) {
      XCTFail("A signing failure must not attempt to update or weaken access control")
      return errSecSuccess
    })
    try BiometricStore.finishEnrollment(status: errSecSuccess) {
      XCTFail("A new enrollment does not need an update")
      return errSecSuccess
    }
  }

  func testSigningFailureIsNotReportedAsMissingFingerprints() {
    let message = KeychainFailure.status(errSecMissingEntitlement).message(chinese: true)
    XCTAssertTrue(message.contains("签名权限"))
    XCTAssertTrue(message.contains("-34018"))
    XCTAssertFalse(message.contains("添加指纹"))
    XCTAssertTrue(KeychainFailure.authentication(LAError.biometryNotEnrolled.rawValue)
      .message(chinese: true).contains("添加指纹"))
    XCTAssertTrue(KeychainFailure.status(errSecItemNotFound)
      .message(chinese: true).contains("重新启用"))
  }
}
