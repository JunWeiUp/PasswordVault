import CryptoKit
import Foundation

enum BreachCheckError: Error { case invalidResponse }

enum PasswordBreachCheck {
  static func hash(_ password: String) -> String {
    Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
  }
  static func request(prefix: String) throws -> URLRequest {
    guard prefix.count == 5, prefix.allSatisfy({ $0.isASCII && $0.isHexDigit }),
      let url = URL(string: "https://api.pwnedpasswords.com/range/" + prefix.uppercased())
    else { throw BreachCheckError.invalidResponse }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.setValue("true", forHTTPHeaderField: "Add-Padding")
    request.setValue("PasswordVault", forHTTPHeaderField: "User-Agent")
    return request
  }
  static func parse(_ data: Data) throws -> [String: Int] {
    guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
      !text.isEmpty
    else { throw BreachCheckError.invalidResponse }
    var counts: [String: Int] = [:]
    let lines = text.split(whereSeparator: \.isNewline)
    guard !lines.isEmpty else { throw BreachCheckError.invalidResponse }
    for line in lines {
      let pieces = line.split(separator: ":", omittingEmptySubsequences: false)
      guard pieces.count == 2, pieces[0].count == 35,
        pieces[0].allSatisfy({ $0.isASCII && $0.isHexDigit }),
        let count = Int(pieces[1]), count >= 0
      else { throw BreachCheckError.invalidResponse }
      if count > 0 { counts[String(pieces[0]).uppercased()] = count }
    }
    return counts
  }
  static func passwords(_ item: VaultItem) -> [String] {
    guard !item.isDeleted, ["password", "totp"].contains(item.type) else { return [] }
    return
      ([item.password]
      + (item.fields["accounts"]?.array ?? []).map { $0.object["password"]?.string ?? "" }).filter {
        !$0.isEmpty
      }
  }
  static func check(_ items: [VaultItem]) async throws -> Set<String> {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.httpCookieStorage = nil
    let session = URLSession(
      configuration: config, delegate: BreachRedirectGuard(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return try await check(items, load: { try await session.data(for: $0) })
  }
  static func check(_ items: [VaultItem], load: (URLRequest) async throws -> (Data, URLResponse))
    async throws -> Set<String>
  {
    var prefixes: [String: [String: Set<String>]] = [:]
    var affected = Set<String>()
    for item in items {
      for password in passwords(item) {
        try Task.checkCancellation()
        let digest = hash(password)
        let prefix = String(digest.prefix(5))
        prefixes[prefix, default: [:]][String(digest.dropFirst(5)), default: []].insert(item.id)
      }
    }
    // Fetch each prefix once, retaining at most one provider response at a time.
    for (prefix, suffixes) in prefixes {
      try Task.checkCancellation()
      let (data, response) = try await load(request(prefix: prefix))
      guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
        throw BreachCheckError.invalidResponse
      }
      let counts = try parse(data)
      for (suffix, ids) in suffixes where counts[suffix] != nil { affected.formUnion(ids) }
    }
    try Task.checkCancellation()
    return affected
  }
}

private final class BreachRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Do not forward credential hash prefixes to redirected hosts.
    completionHandler(nil)
  }
}
