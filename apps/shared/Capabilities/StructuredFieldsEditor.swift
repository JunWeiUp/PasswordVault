import SwiftUI
import UniformTypeIdentifiers

/// Shared by the native editors; nested records and unknown fields survive every edit.
struct StructuredFieldsEditor: View {
  @Binding var item: VaultItem
  @State private var exportDocument: ImportedAttachmentDocument?
  @State private var exportName = "attachment"
  @State private var exporting = false
  @State private var exportError = ""
  @State private var revealing = Set<String>()
  let t: (String, String) -> String
  private let card = [("cardholder", "持卡人", "Cardholder"), ("number", "卡号", "Card number"), ("expiryMonth", "到期月", "Expiry month"), ("expiryYear", "到期年", "Expiry year"), ("securityCode", "安全码", "Security code"), ("brand", "卡组织", "Card brand")]
  private let identity = [("firstName", "名", "First name"), ("lastName", "姓", "Last name"), ("email", "邮箱", "Email"), ("phone", "电话", "Phone"), ("address1", "地址", "Address"), ("address2", "地址补充", "Address line 2"), ("city", "城市", "City"), ("region", "省 / 州", "Region"), ("postalCode", "邮编", "Postal code"), ("country", "国家", "Country"), ("company", "公司", "Company")]
  var body: some View {
    if item.type == "creditCard" || item.type == "identity" {
      let group = item.type == "creditCard" ? "card" : "identity"
      Section(t(item.type == "creditCard" ? "银行卡" : "身份资料", item.type == "creditCard" ? "Payment card" : "Identity")) {
        ForEach(item.type == "creditCard" ? card : identity, id: \.0) { key, zh, en in
          if key == "number" || key == "securityCode" {
            HStack { if revealing.contains(key) { TextField(t(zh, en), text: nested(group, key)) } else { SecureField(t(zh, en), text: nested(group, key)) }
              Button(revealing.contains(key) ? t("隐藏", "Hide") : t("显示", "Reveal")) { if revealing.contains(key) { revealing.remove(key) } else { revealing.insert(key) } }
            }
          }
          else { TextField(t(zh, en), text: nested(group, key)) }
        }
      }
    }
    if let attachments = item.fields["importSource"]?.object["attachments"]?.array, !attachments.isEmpty {
      Section(t("导入的附件", "Imported attachments")) {
        ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
          Button(attachment.object["name"]?.string ?? t("附件", "Attachment")) {
            guard let encoded = attachment.object["data"]?.string, let data = Data(base64Encoded: encoded) else { exportError = t("附件数据损坏", "Attachment data is damaged"); return }
            exportDocument = ImportedAttachmentDocument(data: data)
            exportName = (attachment.object["name"]?.string ?? "attachment").components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? "attachment"
            exporting = true
          }
        }
        if !exportError.isEmpty { Text(exportError).foregroundStyle(.red) }
      }.fileExporter(isPresented: $exporting, document: exportDocument, contentType: .data, defaultFilename: exportName) { result in
        if case .failure = result { exportError = t("无法导出附件", "Could not export attachment") }
        exportDocument = nil
      }
    }
    Section(t("自定义字段", "Custom fields")) {
      ForEach(Array((item.fields["customFields"]?.array ?? []).enumerated()), id: \.offset) { index, value in
        VStack(alignment: .leading) {
          TextField(t("字段名称", "Field label"), text: custom(index, "label"))
          TextField(t("分组", "Group"), text: custom(index, "group"))
          Picker(t("类型", "Type"), selection: custom(index, "kind")) {
            Text(t("文字", "Text")).tag("text")
            Text(t("隐藏内容", "Concealed")).tag("concealed")
            Text(t("网址", "URL")).tag("url")
            Text(t("邮箱", "Email")).tag("email")
            Text(t("日期", "Date")).tag("date")
          }
          if value.object["kind"]?.string == "concealed" {
            let key = "custom-\(index)"
            HStack { if revealing.contains(key) { TextField(t("内容", "Value"), text: custom(index, "value")) } else { SecureField(t("内容", "Value"), text: custom(index, "value")) }
              Button(revealing.contains(key) ? t("隐藏", "Hide") : t("显示", "Reveal")) { if revealing.contains(key) { revealing.remove(key) } else { revealing.insert(key) } }
            }
          }
          else { TextField(t("内容", "Value"), text: custom(index, "value")) }
          Button(t("移除字段", "Remove field"), role: .destructive) {
            var values = item.fields["customFields"]?.array ?? []
            guard values.indices.contains(index) else { return }
            values.remove(at: index); item.fields["customFields"] = .array(values)
          }
        }
      }
      Button(t("添加字段", "Add field")) {
        var values = item.fields["customFields"]?.array ?? []
        values.append(.object(["id": .string(UUID().uuidString), "label": .string(""), "kind": .string("concealed"), "value": .string("")]))
        item.fields["customFields"] = .array(values)
      }.disabled((item.fields["customFields"]?.array.count ?? 0) >= 256)
    }
  }
  private func nested(_ group: String, _ key: String) -> Binding<String> {
    Binding(get: { item.fields[group]?.object[key]?.string ?? "" }, set: { value in
      var object = item.fields[group]?.object ?? [:]; object[key] = .string(value); item.fields[group] = .object(object)
    })
  }
  private func custom(_ index: Int, _ key: String) -> Binding<String> {
    Binding(get: { let values = item.fields["customFields"]?.array ?? []; return values.indices.contains(index) ? values[index].object[key]?.string ?? "" : "" }, set: { value in
      var values = item.fields["customFields"]?.array ?? []; guard values.indices.contains(index) else { return }
      var object = values[index].object; object[key] = .string(value); values[index] = .object(object); item.fields["customFields"] = .array(values)
    })
  }
}

private struct ImportedAttachmentDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  let data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
