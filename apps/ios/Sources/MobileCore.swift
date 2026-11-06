import Foundation

actor MobileCore {
  private var session: VaultSession?
  init(directory: URL) throws { session = try VaultSession(directory: directory.path) }
  func call(_ request: [String: JSONValue]) throws -> JSONValue {
    guard let session else { throw VaultError.Locked }
    var request = request
    if ["export", "import", "create-from-backup", "remove", "save"].contains(request["op"]?.string ?? "") {
      request["richNotes"] = .bool(true)
    }
    let data = try JSONEncoder().encode(request)
    let response = try session.command(request: String(decoding: data, as: UTF8.self))
    return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
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
