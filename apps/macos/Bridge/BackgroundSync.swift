import CryptoKit
import Foundation
import Security

// Keys stay in the helper's Keychain/verified native IPC boundary, never browser output.
enum BackgroundSync {
  static let service = "com.securepass.vault.browser-background-save.v1"
  private static let desktopService = "com.securepass.vault.browser-desktop-unlock.v1"
  struct Authorization: Codable {
    var grant: Data
    var allowRead: Bool
    var autoUnlock: Bool
  }
  private struct DesktopOwner: Codable {
    let extensionID: String
    let token: String
  }
  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func query(directory: URL, extensionID: String, token: String) throws -> [String: Any] {
    guard token.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw VaultError.Authentication
    }
    let identity = directory.standardizedFileURL.path + "\n" + extensionID + "\n" + token
    return baseQuery(service: service, account: digest(identity))
  }
  private static func baseQuery(service: String, account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
  }
  private static func desktopQuery(_ directory: URL) throws -> [String: Any] {
    // A changed ad-hoc signature cannot update an old helper-owned Keychain item.
    // Namespace the startup index by the code identity so explicit reauthorization
    // after an update can create a fresh index without weakening the old ACL.
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess,
      let code else { throw VaultError.Storage }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw VaultError.Storage }
    return baseQuery(service: desktopService,
      account: digest(directory.standardizedFileURL.path + "\n" + hash.base64EncodedString()))
  }
  private static func load(_ query: [String: Any]) throws -> Data {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data else { throw VaultError.Authentication }
    return data
  }
  private static func store(_ data: Data, query: [String: Any]) throws {
    var trusted: SecTrustedApplication?
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    guard SecTrustedApplicationCreateFromPath(helper, &trusted) == errSecSuccess,
      let trusted else { throw VaultError.Storage }
    var access: SecAccess?
    guard SecAccessCreate("PasswordVault browser authorization" as CFString,
      [trusted] as CFArray, &access) == errSecSuccess, let access else { throw VaultError.Storage }
    var entry = query
    entry.removeValue(forKey: kSecUseAuthenticationUI as String)
    entry[kSecValueData as String] = data
    entry[kSecAttrLabel as String] = "PasswordVault browser authorization"
    entry[kSecAttrAccess as String] = access
    let result = SecItemAdd(entry as CFDictionary, nil)
    let updated = result == errSecDuplicateItem
      ? SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) : result
    guard updated == errSecSuccess else { throw VaultError.Storage }
  }
  private static func remove(_ query: [String: Any]) throws {
    let result = SecItemDelete(query as CFDictionary)
    guard result == errSecSuccess || result == errSecItemNotFound else { throw VaultError.Storage }
  }
  static func authorization(directory: URL, extensionID: String, token: String) throws -> Authorization {
    var bytes = try load(query(directory: directory, extensionID: extensionID, token: token))
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    // An old 64-byte grant retains append-only scope. Never silently upgrade it.
    var auth = bytes.count == 64
      ? Authorization(grant: bytes, allowRead: false, autoUnlock: false)
      : try JSONDecoder().decode(Authorization.self, from: bytes)
    guard try backgroundGrantValid(directory: directory.path, grant: auth.grant) else {
      auth.grant.resetBytes(in: 0..<auth.grant.count)
      try? revoke(directory: directory, extensionID: extensionID, token: token)
      throw VaultError.Authentication
    }
    return auth
  }
  static func read(directory: URL, extensionID: String, token: String) throws -> Data {
    try authorization(directory: directory, extensionID: extensionID, token: token).grant
  }
  static func configure(directory: URL, extensionID: String, token: String, password: String,
    allowRead: Bool = false, autoUnlock: Bool = false) throws {
    guard !autoUnlock || allowRead else { throw VaultError.InvalidData }
    var grant = try createBackgroundGrant(directory: directory.path, password: password)
    defer { grant.resetBytes(in: 0..<grant.count) }
    let auth = Authorization(grant: grant, allowRead: allowRead, autoUnlock: autoUnlock)
    var encoded = try JSONEncoder().encode(auth)
    defer { encoded.resetBytes(in: 0..<encoded.count) }
    try store(encoded, query: query(directory: directory, extensionID: extensionID, token: token))
    if autoUnlock {
      do {
        let owner = DesktopOwner(extensionID: extensionID, token: token)
        try store(JSONEncoder().encode(owner), query: desktopQuery(directory))
      } catch {
        // Failed setup must not leave a newly enabled capability behind.
        try? revoke(directory: directory, extensionID: extensionID, token: token)
        throw error
      }
    } else { try disableDesktop(directory: directory, extensionID: extensionID, token: token) }
  }
  static func desktopOwner(directory: URL, extensionID: String, token: String) -> Bool {
    guard let bytes = try? load(desktopQuery(directory)),
      let owner = try? JSONDecoder().decode(DesktopOwner.self, from: bytes) else { return false }
    return owner.extensionID == extensionID && owner.token == token
  }
  static func desktopGrant(directory: URL, extensionID: String) throws -> Data {
    let owner = try JSONDecoder().decode(DesktopOwner.self, from: load(desktopQuery(directory)))
    guard owner.extensionID == extensionID else { throw VaultError.Authentication }
    let auth = try authorization(directory: directory, extensionID: extensionID, token: owner.token)
    guard auth.autoUnlock && auth.allowRead else { throw VaultError.Authentication }
    return auth.grant
  }
  static func disableDesktop(directory: URL, extensionID: String, token: String) throws {
    if desktopOwner(directory: directory, extensionID: extensionID, token: token) {
      try remove(desktopQuery(directory))
    }
  }
  static func revoke(directory: URL, extensionID: String, token: String) throws {
    // Removing the underlying capability also invalidates any inaccessible owner index.
    try remove(query(directory: directory, extensionID: extensionID, token: token))
    try disableDesktop(directory: directory, extensionID: extensionID, token: token)
  }
}
