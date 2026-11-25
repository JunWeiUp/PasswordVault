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

/// RFC 4918 listing decoder backed by `vault-core`'s shared `webdavParseListing`.
enum WebDAVListing {
  static func parse(_ data: Data, base: URL) throws -> [RemoteBackup] {
    guard data.count <= 8 * 1024 * 1024, let xml = String(data: data, encoding: .utf8) else {
      throw VaultError.InvalidData
    }
    let json = try webdavParseListing(base: base.absoluteString, xml: xml, strictHrefs: false)
    return try decodeCoreJSON(json)
  }

  static func decodeCoreJSON(_ json: String) throws -> [RemoteBackup] {
    struct Row: Decodable {
      let url: String
      let modified: String?
      let created: String?
      let size: Int64?
    }
    let rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8))
    return rows.compactMap { row in
      guard let url = URL(string: row.url) else { return nil }
      return RemoteBackup(
        url: url,
        modifiedAt: row.modified.flatMap(parseDate),
        createdAt: row.created.flatMap(parseDate),
        byteCount: row.size.flatMap { $0 >= 0 ? $0 : nil }
      )
    }.sorted { left, right in
      if left.backupDate != right.backupDate {
        return (left.backupDate ?? .distantPast) > (right.backupDate ?? .distantPast)
      }
      return left.name.localizedStandardCompare(right.name) == .orderedDescending
    }
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
