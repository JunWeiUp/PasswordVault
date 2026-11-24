import Foundation

actor MobileCore {
  private var session: VaultSession?
  init(directory: URL) throws { session = try VaultSession(directory: directory.path) }
  /// The open core session (for the relay's shared sync session).
  func coreSession() throws -> VaultSession {
    guard let session else { throw VaultError.Locked }
    return session
  }
  func call(_ request: [String: JSONValue]) throws -> JSONValue {
    guard let session else { throw VaultError.Locked }
    var request = request
    if ["export", "import", "create-from-backup", "remove", "save"].contains(request["op"]?.string ?? "") {
      request["richNotes"] = .bool(true)
    }
    let response = try session.command(request: Self.encode(request))
    return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
  }
  private static func encode(_ request: [String: JSONValue]) throws -> String {
    String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
  }
  func importAttachment(noteID: String, name: String, mime: String, data: Data) throws -> JSONValue {
    guard let session else { throw VaultError.Locked }
    return try JSONDecoder().decode(JSONValue.self, from: Data(session.importNoteAttachment(noteId: noteID, name: name, mime: mime, data: data).utf8))
  }
  func readAttachment(noteID: String, id: String) throws -> Data {
    guard let session else { throw VaultError.Locked }; return try session.readNoteAttachment(noteId: noteID, id: id)
  }
  func discardAttachment(noteID: String, id: String) throws {
    guard let session else { throw VaultError.Locked }; try session.discardNoteAttachment(noteId: noteID, id: id)
  }
  func document() throws -> VaultDocument {
    guard let session else { throw VaultError.Locked }
    return try JSONDecoder().decode(
      VaultDocument.self, from: Data(session.command(request: Self.encode(CoreRequest.list(summaries: true))).utf8))
  }
  func getItem(id: String) throws -> VaultItem {
    guard let session else { throw VaultError.Locked }
    let response = try session.command(request: Self.encode(CoreRequest.get(id: id)))
    return try JSONDecoder().decode(VaultItem.self, from: Data(response.utf8))
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
    if let request = try? Self.encode(CoreRequest.lock()) { _ = try? session?.command(request: request) }
    session = nil
  }
}
