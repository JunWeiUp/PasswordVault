import AuthenticationServices
import Foundation

/// QuickType suggestions: the system's identity store gets each account's site, username and
/// entry ID — never a password. Choosing a suggestion opens the AutoFill extension, which
/// requires unlocking before it provides anything.
enum CredentialSuggestions {
  static let defaultsKey = "quickTypeSuggestions"

  /// Suggestions are on unless the user turned them off in AutoFill settings.
  static var enabled: Bool {
    UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
  }

  struct Entry: Equatable {
    let host: String
    let user: String
    let record: String
  }

  /// One entry per account with a username on a live password item that has an http(s) site.
  static func entries(_ items: [VaultItem]) -> [Entry] {
    var result: [Entry] = []
    for item in items where item.type == "password" && !item.isDeleted {
      guard let host = host(item.string("url")) else { continue }
      if !item.username.isEmpty { result.append(Entry(host: host, user: item.username, record: item.id)) }
      for (index, account) in (item.fields["accounts"]?.array ?? []).enumerated() {
        let user = account.object["username"]?.string ?? ""
        if !user.isEmpty { result.append(Entry(host: host, user: user, record: "\(item.id)#\(index + 1)")) }
      }
    }
    return result
  }

  /// The host of the first http(s) URL in a site field (one or more lines).
  static func host(_ value: String) -> String? {
    for line in value.split(whereSeparator: \.isNewline) {
      let raw = line.trimmingCharacters(in: .whitespaces)
      let candidate = raw.contains("://") ? raw : "https://" + raw
      guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
        ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
        url.user == nil, url.password == nil
      else { continue }
      return host.lowercased()
    }
    return nil
  }

  static func identities(_ items: [VaultItem]) -> [ASPasswordCredentialIdentity] {
    entries(items).map {
      ASPasswordCredentialIdentity(
        serviceIdentifier: ASCredentialServiceIdentifier(identifier: $0.host, type: .domain),
        user: $0.user, recordIdentifier: $0.record)
    }
  }
}
