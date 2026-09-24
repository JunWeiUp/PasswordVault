import Foundation

/// Compare all automatic writes in one editing session against the same baseline,
/// rather than recording every partially typed password as a new history entry.
enum EntryPasswordHistory {
  static func normalizeAccountIDs(_ item: VaultItem) -> VaultItem {
    var result = item, seen = Set<String>()
    if let accounts = item.fields["accounts"]?.array {
      result.fields["accounts"] = .array(accounts.map { account in
        var fields = account.object
        let id = fields["id"]?.string ?? ""
        if id.isEmpty || !seen.insert(id).inserted { fields["id"] = .string(UUID().uuidString) }
        return .object(fields)
      })
    }
    return result
  }

  static func credentialState(_ item: VaultItem) -> [JSONValue?] {
    ["password", "passwordHistory", "passwordLastChanged", "accounts"].map { item.fields[$0] }
  }

  static func prepare(_ draft: VaultItem, baseline: VaultItem?, changedAt: String) -> VaultItem {
    var result = draft
    func update(_ next: inout [String: JSONValue], _ old: [String: JSONValue]?) {
      let password = next["password"]?.string ?? ""
      guard let old else {
        if !password.isEmpty && next["passwordLastChanged"] == nil { next["passwordLastChanged"] = .string(changedAt) }
        return
      }
      let previous = old["password"]?.string ?? ""
      if password == previous {
        if let history = old["passwordHistory"] { next["passwordHistory"] = history }
        else { next.removeValue(forKey: "passwordHistory") }
        if let time = old["passwordLastChanged"] { next["passwordLastChanged"] = time }
        else { next.removeValue(forKey: "passwordLastChanged") }
        return
      }
      var history = old["passwordHistory"]?.array ?? []
      if !previous.isEmpty { history.insert(.object(["password": .string(previous), "changedAt": .string(changedAt)]), at: 0) }
      next["passwordHistory"] = .array(history)
      next["passwordLastChanged"] = .string(changedAt)
    }
    update(&result.fields, baseline?.fields)
    if let accounts = draft.fields["accounts"]?.array {
      result.fields["accounts"] = .array(accounts.map { account in
        var fields = account.object
        let old = baseline?.fields["accounts"]?.array.first { $0.object["id"] == fields["id"] }
        update(&fields, old?.object)
        return .object(fields)
      })
    }
    return result
  }
}
