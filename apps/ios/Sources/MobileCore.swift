import Foundation

actor MobileCore {
  private var session: VaultSession?
  init(directory: URL) throws { session = try VaultSession(directory: directory.path) }
  func call(_ request: [String: JSONValue]) throws -> JSONValue {
    guard let session else { throw VaultError.Locked }
    let data = try JSONEncoder().encode(request)
    let response = try session.command(request: String(decoding: data, as: UTF8.self))
    return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
  }
  func document() throws -> VaultDocument {
    guard let session else { throw VaultError.Locked }
    return try JSONDecoder().decode(
      VaultDocument.self, from: Data(session.command(request: "{\"op\":\"list\"}").utf8))
  }
  func biometricKey() throws -> Data {
    guard let session else { throw VaultError.Locked }
    return Data(try session.biometricKey())
  }
  func unlockBiometric(_ key: Data) throws {
    guard let session else { throw VaultError.Locked }
    try session.unlockBiometric(key: key)
  }
  func close() {
    _ = try? session?.command(request: "{\"op\":\"lock\"}")
    session = nil
  }
}
