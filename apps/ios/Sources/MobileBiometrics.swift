import Foundation
import LocalAuthentication
import Security

enum MobileBiometrics {
  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "PasswordVault") + ".biometric",
      kSecAttrAccount as String: "vault-root",
    ]
  }
  static var available: Bool {
    var error: NSError?
    return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
  }
  /// "Face ID" / "Touch ID" / "Optic ID" for the hardware this device has.
  static func name(_ t: (String, String) -> String) -> String {
    let context = LAContext()
    var error: NSError?
    _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    switch context.biometryType {
    case .touchID: return t("触控 ID", "Touch ID")
    case .opticID: return t("视控 ID", "Optic ID")
    default: return t("面容 ID", "Face ID")
    }
  }
  static func enroll(_ key: Data) throws {
    guard available else { throw VaultError.InvalidData }
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error)
    else { throw VaultError.InvalidData }
    var entry = query
    entry[kSecAttrAccessControl as String] = access
    entry[kSecValueData as String] = key
    // Updating keeps the old key intact if re-enrollment fails.
    let status = SecItemAdd(entry as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: key, kSecAttrAccessControl as String: access] as CFDictionary)
      guard update == errSecSuccess else { throw VaultError.Authentication }
    } else if status != errSecSuccess {
      throw VaultError.Authentication
    }
  }
  static func remove() { SecItemDelete(query as CFDictionary) }
  static func load(reason: String) async throws -> Data {
    try await Task.detached {
      let context = LAContext()
      context.localizedReason = reason
      var request = query
      request[kSecUseAuthenticationContext as String] = context
      request[kSecReturnData as String] = true
      request[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data
      else { throw VaultError.Authentication }
      return data
    }.value
  }
}
