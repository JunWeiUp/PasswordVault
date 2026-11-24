import Foundation

/// Identity document data (type, number, issuer, dates). Released cores whitelist the keys of
/// an identity record and reject unknown ones, so documents live in `customFields` under fixed
/// ids shared with the desktop and Android clients. Names stay in identity firstName/lastName.
enum IdentityDocument {
  struct Spec {
    let id: String
    /// Stored label (the cross-platform schema stores the Chinese label).
    let label: String
    let english: String
    let kind: String
  }
  static let group = "document"
  static let fields: [Spec] = [
    Spec(id: "document.type", label: "证件类型", english: "Document type", kind: "text"),
    Spec(id: "document.number", label: "证件号码", english: "Document number", kind: "concealed"),
    Spec(id: "document.issuer", label: "签发机关", english: "Issued by", kind: "text"),
    Spec(id: "document.issueDate", label: "签发日期", english: "Issue date", kind: "date"),
    Spec(id: "document.expiryDate", label: "有效期至", english: "Expires", kind: "date"),
  ]

  static func spec(_ id: String) -> Spec? { fields.first { $0.id == id } }
  static func isDocument(_ field: JSONValue) -> Bool { spec(field.object["id"]?.string ?? "") != nil }

  /// Localized label for a known document field; other fields keep their stored label.
  static func label(_ field: JSONValue, t: (String, String) -> String) -> String {
    if let spec = spec(field.object["id"]?.string ?? "") { return t(spec.label, spec.english) }
    return field.object["label"]?.string ?? ""
  }

  static func value(_ fields: [JSONValue], _ id: String) -> String {
    fields.first { $0.object["id"]?.string == id }?.object["value"]?.string ?? ""
  }

  /// Returns the custom field list with one document value set. Existing fields keep their
  /// position, label and unknown keys; a missing field is appended only when it gets a value.
  static func setting(_ fields: [JSONValue], _ id: String, _ value: String) -> [JSONValue] {
    guard let spec = spec(id) else { return fields }
    var list = fields
    if let index = list.firstIndex(where: { $0.object["id"]?.string == id }) {
      var object = list[index].object
      object["value"] = .string(value)
      list[index] = .object(object)
    } else if !value.isEmpty {
      list.append(.object([
        "id": .string(id), "group": .string(group), "label": .string(spec.label),
        "kind": .string(spec.kind), "value": .string(value),
      ]))
    }
    return list
  }

  /// Dates are stored as `YYYY-MM-DD`; an empty value is allowed.
  static func validDate(_ value: String) -> Bool { value.isEmpty || date(value) != nil }

  static func date(_ value: String) -> Date? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard value.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = DateComponents(year: year, month: month, day: day)
    guard let date = calendar.date(from: components),
      calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
    else { return nil }
    return date
  }

  static func string(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
}

/// Localized labels for the structured card and identity records.
enum StructuredLabels {
  static let card: [(String, String, String)] = [
    ("cardholder", "持卡人", "Cardholder"), ("number", "卡号", "Card number"),
    ("expiryMonth", "到期月", "Expiry month"), ("expiryYear", "到期年", "Expiry year"),
    ("securityCode", "安全码", "Security code"), ("brand", "卡组织", "Card brand"),
  ]
  static let identity: [(String, String, String)] = [
    ("lastName", "姓", "Last name"), ("firstName", "名", "First name"), ("email", "邮箱", "Email"),
    ("phone", "电话", "Phone"), ("address1", "地址", "Address"), ("address2", "地址补充", "Address line 2"),
    ("city", "城市", "City"), ("region", "省 / 州", "Region"), ("postalCode", "邮编", "Postal code"),
    ("country", "国家", "Country"), ("company", "公司", "Company"),
  ]
  static func label(_ key: String, type: String, t: (String, String) -> String) -> String {
    let table = type == "creditCard" ? card : identity
    guard let entry = table.first(where: { $0.0 == key }) else { return key }
    return t(entry.1, entry.2)
  }
}
