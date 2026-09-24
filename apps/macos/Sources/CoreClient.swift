import Foundation

actor CoreClient {
  private let session: VaultSession

  init(directory: URL) throws {
    session = try VaultSession(directory: directory.path)
  }

  func call(_ request: [String: JSONValue]) throws -> JSONValue {
    let bytes = try JSONEncoder().encode(request)
    let response = try session.command(request: String(decoding: bytes, as: UTF8.self))
    return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
  }

  func document() throws -> VaultDocument {
    let response = try session.command(request: "{\"op\":\"list\"}")
    return try JSONDecoder().decode(VaultDocument.self, from: Data(response.utf8))
  }

  /// Snapshot failed drafts under the vault root key before releasing it. No plaintext recovery file.
  func lockWithPending(_ items: [VaultItem]) -> JSONValue? {
    var recovery: JSONValue?
    var failed = false
    if !items.isEmpty {
      recovery = try? call(["op": .string("seal-drafts"), "items": try! .from(items)])
      for item in items {
        do { _ = try call(["op": .string("save"), "item": try .from(item)]) } catch {
          failed = true
        }
      }
    }
    _ = try? call(["op": .string("lock")])
    return failed ? recovery : nil
  }

  func biometricKey() throws -> Data { Data(try session.biometricKey()) }
  func unlockBiometric(_ key: Data) throws { try session.unlockBiometric(key: key) }
}
