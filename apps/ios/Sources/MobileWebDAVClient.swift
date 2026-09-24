import Foundation

final class WebDAVClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let base: URL
  private let authorization: String
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 90
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  init(url: String, username: String, password: String, folder: String) throws {
    guard let root = URL(string: url), root.host != nil, root.user == nil, root.password == nil,
      root.scheme == "https"
        || (root.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(root.host ?? "")),
      !folder.contains(".."), !folder.hasPrefix("/")
    else { throw VaultError.InvalidData }
    base = root.appendingPathComponent(folder, isDirectory: true)
    authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, sameOrigin(url), withinFolder(url) else {
      completionHandler(nil)
      return
    }
    var redirected = request
    redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
    completionHandler(redirected)
  }

  private func sameOrigin(_ url: URL) -> Bool {
    url.scheme == base.scheme && url.host == base.host && url.port == base.port
  }
  private func withinFolder(_ url: URL) -> Bool {
    let root = base.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path == root || path.hasPrefix(root + "/")
  }
  private func request(_ method: String, url: URL, body: Data? = nil) async throws -> Data {
    guard sameOrigin(url), withinFolder(url) else { throw VaultError.InvalidData }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    if method == "PROPFIND" {
      request.setValue("1", forHTTPHeaderField: "Depth")
      request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    }
    if method == "PUT" {
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      request.setValue("*", forHTTPHeaderField: "If-None-Match")
    }
    let (stream, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw WebDAVFailure.server }
    if !(200..<300).contains(response.statusCode)
      && !(method == "MKCOL" && response.statusCode == 405)
    {
      switch response.statusCode {
      case 401: throw WebDAVFailure.authentication
      case 403: throw WebDAVFailure.permission
      case 404: throw WebDAVFailure.notFound
      default: throw WebDAVFailure.server
      }
    }
    var data = Data()
    for try await byte in stream {
      guard data.count < 64 * 1024 * 1024 else { throw VaultError.InvalidData }
      data.append(byte)
    }
    return data
  }
  func close() { session.invalidateAndCancel() }
  func list() async throws -> [RemoteBackup] {
    let data = try await request("PROPFIND", url: base, body: WebDAVListing.requestBody)
    do { return try WebDAVListing.parse(data, base: base) } catch {
      throw WebDAVFailure.invalidListing
    }
  }
  func upload(_ data: Data) async throws {
    _ = try await request("MKCOL", url: base)
    let name =
      "PasswordVault-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).pvbackup"
    _ = try await request("PUT", url: base.appendingPathComponent(name), body: data)
  }
  func download(_ backup: RemoteBackup) async throws -> Data {
    try await request("GET", url: backup.url)
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
