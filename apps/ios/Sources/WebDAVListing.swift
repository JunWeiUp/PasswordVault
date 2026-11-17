import Foundation

struct RemoteBackup: Identifiable {
  let url: URL
  var modifiedAt: Date? = nil
  var createdAt: Date? = nil
  var byteCount: Int64? = nil
  var id: String { url.absoluteString }
  var name: String { url.lastPathComponent }
  // A filename hint for guidance only; the core detects and validates the actual file format.
  var isLegacyEncrypted: Bool {
    name.lowercased().hasPrefix("backup_enc_")
      || name.lowercased().hasPrefix("securepass_backup_enc_")
  }
  var backupDate: Date? { modifiedAt ?? createdAt ?? Self.dateFromFilename(name) }

  func timeLabel(chinese: Bool) -> String {
    guard let date = backupDate else { return chinese ? "时间未知" : "Time unavailable" }
    return date.formatted(
      Date.FormatStyle(date: .numeric, time: .shortened)
        .locale(Locale(identifier: chinese ? "zh_CN" : "en_US")))
  }

  var sizeLabel: String? {
    guard let byteCount else { return nil }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.includesActualByteCount = false
    formatter.zeroPadsFractionDigits = false
    return formatter.string(fromByteCount: byteCount)
  }

  func timeExplanation(chinese: Bool) -> String {
    if modifiedAt != nil {
      return chinese ? "服务器修改时间，按本机时区显示" : "Server modification time in your local time zone"
    }
    if createdAt != nil {
      return chinese ? "服务器创建时间，按本机时区显示" : "Server creation time in your local time zone"
    }
    return chinese
      ? "服务器未提供时间；从备份文件名识别" : "Server time unavailable; date recognized from the backup filename"
  }

  static func dateFromFilename(_ name: String) -> Date? {
    let stem = (name as NSString).deletingPathExtension
    guard let prefix = ["backup_enc_", "backup_", "PasswordVault-"].first(where: stem.hasPrefix)
    else { return nil }
    let digits = String(stem.dropFirst(prefix.count))
    guard [10, 13].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
      let value = Double(digits)
    else { return nil }
    return Date(timeIntervalSince1970: digits.count == 13 ? value / 1000 : value)
  }
}

/// RFC 4918: properties belong to one response and only successful propstat groups apply.
enum WebDAVListing {
  static let requestBody = Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:getlastmodified/><d:creationdate/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>
    """.utf8)

  static func parse(_ data: Data, base: URL) throws -> [RemoteBackup] {
    guard data.count <= 8 * 1024 * 1024 else { throw VaultError.InvalidData }
    let parser = XMLParser(data: data)
    let collector = DAVListingParser()
    parser.delegate = collector
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), collector.validRoot else { throw VaultError.InvalidData }
    var seen: Set<String> = []
    return collector.entries.compactMap { entry in
      guard !entry.isCollection, let href = entry.href,
        let url = URL(string: href, relativeTo: base)?.absoluteURL.standardized,
        url.scheme == base.scheme, url.host == base.host, url.port == base.port,
        url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
        contains(url, in: base), !url.hasDirectoryPath,
        ["pvbackup", "json"].contains(url.pathExtension.lowercased()),
        seen.insert(url.absoluteString).inserted
      else { return nil }
      let size = entry.properties["getcontentlength"].flatMap(Int64.init).flatMap {
        $0 >= 0 ? $0 : nil
      }
      return RemoteBackup(
        url: url, modifiedAt: entry.properties["getlastmodified"].flatMap(parseDate),
        createdAt: entry.properties["creationdate"].flatMap(parseDate), byteCount: size)
    }.sorted { left, right in
      if left.backupDate != right.backupDate {
        return (left.backupDate ?? .distantPast) > (right.backupDate ?? .distantPast)
      }
      return left.name.localizedStandardCompare(right.name) == .orderedDescending
    }
  }

  static func contains(_ url: URL, in base: URL) -> Bool {
    guard !url.pathComponents.contains("..") else { return false }
    let root = base.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path == root || path.hasPrefix(root + "/")
  }

  private static func parseDate(_ value: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: value) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.isLenient = false
    for format in [
      "EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy",
    ] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    return nil
  }
}

private final class DAVListingParser: NSObject, XMLParserDelegate {
  struct Entry {
    var href: String?
    var status: Int?
    var properties: [String: String] = [:]
    var isCollection = false
  }
  struct Node {
    let name: String
    var text = ""
  }
  var entries: [Entry] = []
  var validRoot = false
  private var stack: [Node] = []
  private var current = Entry()
  private var properties: [String: String] = [:]
  private var propertyStatus: Int?
  private var collection = false

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    let name =
      namespaceURI == "DAV:" || namespaceURI == nil || namespaceURI == "" ? elementName : "foreign"
    guard stack.count < 12, entries.count < 20_000 else {
      parser.abortParsing()
      return
    }
    stack.append(Node(name: name))
    if stack.count == 1 {
      validRoot = name == "multistatus"
      if !validRoot { parser.abortParsing() }
    }
    if path == ["multistatus", "response"] { current = Entry() }
    if path == ["multistatus", "response", "propstat"] {
      properties = [:]
      propertyStatus = nil
      collection = false
    }
    if path == ["multistatus", "response", "propstat", "prop", "resourcetype", "collection"] {
      collection = true
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text += string
  }
  func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
    self.parser(parser, foundCharacters: String(decoding: cdataBlock, as: UTF8.self))
  }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard let node = stack.last else { return }
    let currentPath = path
    let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if currentPath == ["multistatus", "response", "href"] { current.href = value }
    if currentPath == ["multistatus", "response", "status"] { current.status = status(value) }
    if currentPath == ["multistatus", "response", "propstat", "status"] {
      propertyStatus = status(value)
    }
    if currentPath.count == 5
      && Array(currentPath.prefix(4)) == ["multistatus", "response", "propstat", "prop"]
    {
      if ["getlastmodified", "creationdate", "getcontentlength"].contains(node.name) {
        properties[node.name] = value
      }
    }
    if currentPath == ["multistatus", "response", "propstat"], let status = propertyStatus,
      (200..<300).contains(status)
    {
      current.properties.merge(properties) { _, new in new }
      current.isCollection = current.isCollection || collection
    }
    if currentPath == ["multistatus", "response"],
      current.status == nil || (200..<300).contains(current.status!)
    {
      entries.append(current)
    }
    stack.removeLast()
  }
  private var path: [String] { stack.map(\.name) }
  private func status(_ value: String) -> Int? {
    let parts = value.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
    return Int(parts[1])
  }
}
