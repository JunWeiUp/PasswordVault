import Foundation

enum JSONValue: Codable, Hashable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([String: JSONValue].self) {
      self = .object(v)
    } else {
      self = .array(try c.decode([JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }

  var string: String {
    if case .string(let v) = self { return v }
    return ""
  }
  var bool: Bool {
    if case .bool(let v) = self { return v }
    return false
  }
  var number: Double {
    if case .number(let v) = self { return v }
    return 0
  }
  var object: [String: JSONValue] {
    if case .object(let v) = self { return v }
    return [:]
  }
  var array: [JSONValue] {
    if case .array(let v) = self { return v }
    return []
  }

  static func from<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
}

struct VaultItem: Codable, Identifiable, Hashable {
  var fields: [String: JSONValue]
  var id: String { fields["id"]?.string ?? "" }
  var type: String { fields["type"]?.string ?? "secureNote" }
  var title: String {
    get { string("title") }
    set { fields["title"] = .string(newValue) }
  }
  var note: String {
    get { string("note") }
    set { fields["note"] = .string(newValue) }
  }
  var username: String {
    get { string("username") }
    set { fields["username"] = .string(newValue) }
  }
  var password: String {
    get { string("password") }
    set { fields["password"] = .string(newValue) }
  }
  var category: String {
    get { string("category") }
    set { fields["category"] = .string(newValue) }
  }
  var isFavorite: Bool {
    get { bool("isFavorite") }
    set { fields["isFavorite"] = .bool(newValue) }
  }
  var isPinned: Bool {
    get { bool("isPinned") }
    set { fields["isPinned"] = .bool(newValue) }
  }
  var isDeleted: Bool {
    get { bool("isDeleted") }
    set { fields["isDeleted"] = .bool(newValue) }
  }
  var tags: [String] {
    get { fields["tags"]?.array.map(\.string) ?? [] }
    set { fields["tags"] = .array(newValue.map(JSONValue.string)) }
  }

  init(fields: [String: JSONValue]) { self.fields = fields }
  init(from decoder: Decoder) throws {
    fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(fields)
  }
  func string(_ key: String) -> String { fields[key]?.string ?? "" }
  func bool(_ key: String) -> Bool { fields[key]?.bool ?? false }
  func number(_ key: String, fallback: Double = 0) -> Double { fields[key]?.number ?? fallback }
  mutating func set(_ key: String, _ value: String) { fields[key] = .string(value) }

  static func blank(type: String, title: String) -> VaultItem {
    VaultItem(fields: [
      "id": .string(UUID().uuidString), "type": .string(type), "title": .string(title),
      "username": .string(""), "note": .string(""), "period": .number(30), "tags": .array([]),
      "noteFormat": .string("markdown"), "isDeleted": .bool(false), "isFavorite": .bool(false),
      "isPinned": .bool(false),
    ])
  }
}

struct VaultDocument: Codable {
  var items: [VaultItem]
  var settings: [String: JSONValue]
  var sharedVaults: [JSONValue]
  var sharedMembers: [JSONValue]
}

enum Destination: String, CaseIterable, Identifiable {
  case notes, passwords, codes, wallets, generator, audit, backups, sharing, trash, settings
  var id: String { rawValue }
  var itemType: String? {
    switch self {
    case .notes: return "secureNote"
    case .passwords: return "password"
    case .codes: return "totp"
    case .wallets: return "crypto"
    default: return nil
    }
  }
  var symbol: String {
    switch self {
    case .notes: return "doc.text"
    case .passwords: return "key.horizontal"
    case .codes: return "timer"
    case .wallets: return "creditcard"
    case .generator: return "wand.and.stars"
    case .audit: return "checkmark.shield"
    case .backups: return "arrow.triangle.2.circlepath.icloud"
    case .sharing: return "person.2"
    case .trash: return "trash"
    case .settings: return "gearshape"
    }
  }
  func title(chinese: Bool) -> String {
    let labels: [Destination: (String, String)] = [
      .notes: ("全部笔记", "All notes"), .passwords: ("密码", "Passwords"),
      .codes: ("验证码", "Codes"), .wallets: ("钱包", "Wallets"),
      .generator: ("密码生成器", "Password generator"),
      .audit: ("密码健康", "Password health"), .backups: ("备份与导入", "Backups & import"),
      .sharing: ("共享资料库", "Shared vaults"), .trash: ("回收站", "Trash"), .settings: ("设置", "Settings"),
    ]
    let pair = labels[self]!
    return chinese ? pair.0 : pair.1
  }
}
