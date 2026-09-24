import Foundation

enum VaultLocation {
  static var directory: URL {
    if let group = Bundle.main.object(forInfoDictionaryKey: "VaultAppGroup") as? String,
      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    {
      return container.appendingPathComponent("PasswordVaultNative", isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PasswordVaultNative", isDirectory: true)
  }
}
