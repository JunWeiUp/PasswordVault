import Foundation
import Darwin
import Security

// A desktop-only helper mode. Browser origins must never receive a root grant.
func validDesktopParent(application: URL) -> Bool {
  var guest: SecCode?
  guard SecCodeCopyGuestWithAttributes(nil,
    [kSecGuestAttributePid as String: getppid()] as CFDictionary, [], &guest) == errSecSuccess,
    let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return false }
  var expected: SecStaticCode?
  let executable = application.appendingPathComponent("Contents/MacOS/PasswordVault")
  guard SecStaticCodeCreateWithPath(executable as CFURL, [], &expected) == errSecSuccess,
    let expected, SecStaticCodeCheckValidity(expected, [], nil) == errSecSuccess else { return false }
  var actual: SecStaticCode?
  guard SecCodeCopyStaticCode(guest, [], &actual) == errSecSuccess, let actual else { return false }
  var a: CFDictionary?, b: CFDictionary?
  guard SecCodeCopySigningInformation(actual, SecCSFlags(rawValue: kSecCSSigningInformation), &a) == errSecSuccess,
    SecCodeCopySigningInformation(expected, SecCSFlags(rawValue: kSecCSSigningInformation), &b) == errSecSuccess,
    let left = (a as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
    let right = (b as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return false }
  return left == right
}
