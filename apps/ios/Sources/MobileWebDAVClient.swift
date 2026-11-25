import Foundation

/// Thin Swift facade over `vault-core`'s shared HTTPS WebDAV client (`webdavList`, `webdavUpload`,
/// `webdavDownload`). All network calls run off the main actor without holding the vault lock.
final class WebDAVClient: @unchecked Sendable {
  let base: URL
  private let configJSON: String

  init(url: String, username: String, password: String, folder: String) throws {
    guard let root = URL(string: url), root.host != nil, root.user == nil, root.password == nil,
      root.scheme == "https"
        || (root.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(root.host ?? "")),
      !folder.contains(".."), !folder.hasPrefix("/")
    else { throw VaultError.InvalidData }
    base = root.appendingPathComponent(folder, isDirectory: true)
    let payload: [String: Any] = [
      "url": url,
      "username": username,
      "password": password,
      "folder": folder,
      "allowLoopbackHttp": root.scheme == "http",
      "strictHrefs": false,
    ]
    let encoded = try JSONSerialization.data(withJSONObject: payload)
    guard let json = String(data: encoded, encoding: .utf8) else { throw VaultError.InvalidData }
    configJSON = json
  }

  private static func mapError(_ error: Error) -> Error {
    guard let davError = error as? WebDavError else { return error }
    switch davError {
    case .Failed(let code):
      switch code {
      case "WebDAVAuthentication": return WebDAVFailure.authentication
      case "WebDAVPermission": return WebDAVFailure.permission
      case "WebDAVNotFound": return WebDAVFailure.notFound
      case "InvalidData": return WebDAVFailure.invalidListing
      default: return WebDAVFailure.server
      }
    }
  }

  func close() {}

  func list() async throws -> [RemoteBackup] {
    let config = configJSON
    let json = try await Task.detached(priority: .userInitiated) {
      do { return try webdavList(configJson: config) }
      catch { throw Self.mapError(error) }
    }.value
    do { return try WebDAVListing.decodeCoreJSON(json) }
    catch { throw WebDAVFailure.invalidListing }
  }

  func upload(_ data: Data) async throws {
    let config = configJSON
    let name =
      "PasswordVault-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).pvbackup"
    try await Task.detached(priority: .userInitiated) {
      do { try webdavUpload(configJson: config, filename: name, data: data) }
      catch { throw Self.mapError(error) }
    }.value
  }

  func download(_ backup: RemoteBackup) async throws -> Data {
    let config = configJSON
    let target = backup.url.absoluteString
    return try await Task.detached(priority: .userInitiated) {
      do { return try webdavDownload(configJson: config, targetUrl: target) }
      catch { throw Self.mapError(error) }
    }.value
  }
}

enum WebDAVFailure: Error { case server, authentication, permission, notFound, invalidListing }

extension RemoteBackup {
  func mobileTimeLabel(chinese: Bool) -> String {
    guard backupDate == nil, name.hasPrefix("PasswordVault-"),
      let stamp = name.dropFirst("PasswordVault-".count).split(separator: "-").first,
      stamp.count == 13, stamp.allSatisfy(\.isNumber), let millis = Double(stamp)
    else { return timeLabel(chinese: chinese) }
    return Date(timeIntervalSince1970: millis / 1000).formatted(
      Date.FormatStyle(date: .numeric, time: .shortened).locale(
        Locale(identifier: chinese ? "zh_CN" : "en_US")))
  }
}
