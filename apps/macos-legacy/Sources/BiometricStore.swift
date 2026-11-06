import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum KeychainFailure: Error {
  case unavailable
  case authentication(Int)
  case status(OSStatus)

  func message(chinese: Bool) -> String {
    switch self {
    case .status(errSecMissingEntitlement):
      return chinese
        ? "当前安装包缺少 Touch ID 所需的钥匙串签名权限。请安装配置了钥匙串权限的签名版本；主密码仍可使用。（-34018）"
        : "This build lacks the signing entitlement required for Touch ID. Install a signed build with Keychain access; your master password remains available. (-34018)"
    case .authentication(LAError.biometryNotEnrolled.rawValue):
      return chinese ? "请先在系统设置的 Touch ID 与密码中添加指纹。" : "Add a fingerprint in System Settings → Touch ID & Password first."
    case .authentication(LAError.biometryLockout.rawValue):
      return chinese ? "Touch ID 已暂时锁定。请先使用系统密码解锁这台 Mac，再重试。" : "Touch ID is locked out. Unlock this Mac with its system password, then retry."
    case .authentication(LAError.userCancel.rawValue), .status(errSecUserCanceled):
      return chinese ? "已取消 Touch ID 操作，仍可使用主密码。" : "Touch ID was cancelled. You can still use your master password."
    case .unavailable, .authentication(LAError.biometryNotAvailable.rawValue):
      return chinese ? "这台 Mac 当前无法使用 Touch ID，请使用主密码。" : "Touch ID is currently unavailable on this Mac. Use your master password."
    case .status(errSecItemNotFound):
      return chinese ? "Touch ID 解锁凭据已失效。请用主密码解锁后，关闭并重新启用 Touch ID。" : "The Touch ID credential is no longer available. Unlock with your master password, then disable and re-enable Touch ID."
    case .status(let code):
      return chinese ? "钥匙串操作未完成（\(code)），请重试或使用主密码。" : "The Keychain operation failed (\(code)). Retry or use your master password."
    case .authentication(let code):
      return chinese ? "Touch ID 操作未完成（\(code)），请重试或使用主密码。" : "Touch ID did not complete (\(code)). Retry or use your master password."
    }
  }
}

struct BiometricStore {
  private static let service = "com.securepass.vault.macos.biometric"

  static var isAvailable: Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
  }

  static func account(for directory: URL) -> String {
    SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  static func enroll(key: Data, account: String) throws {
    var availabilityError: NSError?
    guard LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &availabilityError) else {
      throw KeychainFailure.authentication(availabilityError?.code ?? LAError.biometryNotAvailable.rawValue)
    }
    guard key.count == 32 else { throw KeychainFailure.unavailable }
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet, &error)
    else { throw KeychainFailure.unavailable }
    var attributes = query(account)
    attributes[kSecAttrAccessControl as String] = access
    attributes[kSecAttrSynchronizable as String] = false
    attributes[kSecValueData as String] = key
    let result = SecItemAdd(attributes as CFDictionary, nil)
    try finishEnrollment(status: result) {
      // Replace a stale key while retaining biometric access control. Never treat an
      // existing (possibly obsolete) credential as a successful enrollment.
      SecItemUpdate(query(account) as CFDictionary, [
        kSecValueData as String: key, kSecAttrAccessControl as String: access,
      ] as CFDictionary)
    }
  }

  static func finishEnrollment(status: OSStatus, update: () -> OSStatus) throws {
    let result = status == errSecDuplicateItem ? update() : status
    guard result == errSecSuccess else { throw KeychainFailure.status(result) }
  }

  static func unlock(reason: String, account: String) throws -> Data {
    let context = LAContext()
    context.localizedReason = reason
    context.touchIDAuthenticationAllowableReuseDuration = 0
    var request = query(account)
    request[kSecUseAuthenticationContext as String] = context
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
      throw KeychainFailure.status(status)
    }
    return data
  }

  static func remove(account: String) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainFailure.status(status)
    }
  }
}
