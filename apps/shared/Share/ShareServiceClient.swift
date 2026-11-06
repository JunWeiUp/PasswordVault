import Foundation

enum ShareServiceFailure: Error {
  case configuration
  case response(Int)
}

struct ShareServiceClient {
  let base: URL
  let token: String
  private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
  init(
    endpoint: String, token: String,
    transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil
  ) throws {
    guard let url = URL(string: endpoint), let host = url.host,
      url.scheme == "https"
        || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      ["", "/"].contains(url.path), token.count >= 32
    else { throw ShareServiceFailure.configuration }
    base = url
    self.token = token
    self.transport = transport
  }
  func capabilities() async throws -> JSONValue {
    try await send("api/capabilities", method: "GET")
  }
  func list() async throws -> JSONValue { try await send("api/shares", method: "GET") }
  func revoke(_ id: String) async throws {
    _ = try await send("api/shares/" + validatedID(id), method: "DELETE")
  }
  func create(_ envelope: JSONValue, expiresIn: Int, email: String?) async throws -> String {
    let id = try validatedID(envelope.object["id"]?.string ?? "")
    guard [3600, 86400, 604800, 2_592_000].contains(expiresIn),
      let key = envelope.object["key"]?.string, key.count == 43
    else { throw ShareServiceFailure.configuration }
    var body = envelope.object
    body.removeValue(forKey: "key")
    body["expiresIn"] = .number(Double(expiresIn))
    if let email, !email.isEmpty { body["recipientEmail"] = .string(email) }
    let result = try await send("api/shares", method: "POST", body: .object(body))
    guard result.object["id"]?.string == id else { throw ShareServiceFailure.response(500) }
    var link = URLComponents(
      url: base.appendingPathComponent("s").appendingPathComponent(id),
      resolvingAgainstBaseURL: false)!
    link.fragment = key
    return link.url!.absoluteString
  }
  private func validatedID(_ id: String) throws -> String {
    guard id.count == 32, id.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
      throw ShareServiceFailure.configuration
    }
    return id
  }
  private func send(_ path: String, method: String, body: JSONValue? = nil) async throws
    -> JSONValue
  {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.httpCookieStorage = nil
    let session = URLSession(
      configuration: config, delegate: ShareRedirectGuard(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(
      url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 30)
    request.httpMethod = method
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let result: (Data, URLResponse)
    if let transport {
      result = try await transport(request)
    } else {
      result = try await session.data(for: request)
    }
    let (data, response) = result
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
      data.count <= 1024 * 1024
    else { throw ShareServiceFailure.response((response as? HTTPURLResponse)?.statusCode ?? 0) }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}

private final class ShareRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
