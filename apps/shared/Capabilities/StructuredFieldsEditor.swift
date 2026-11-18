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
  private let card = StructuredLabels.card
  private let identity = StructuredLabels.identity
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
    if item.type == "identity" { documentSection }
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
      // Identity document fields have their own section; every other field is listed here.
      ForEach(Array((item.fields["customFields"]?.array ?? []).enumerated()).filter { item.type != "identity" || !IdentityDocument.isDocument($0.element) }, id: \.offset) { index, value in
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
  /// Identity document fields stored as `customFields` (shared schema with the other clients).
  @ViewBuilder private var documentSection: some View {
    Section(t("证件信息", "Document")) {
      TextField(t("证件类型", "Document type"), text: document("document.type"))
        .accessibilityIdentifier("document.type")
      // Not an account password, so no SecureField (it would trigger the system "Save
      // password?" prompt). A stored number stays masked until revealed; a new one is typed.
      HStack {
        if revealing.contains("document.number") || IdentityDocument.value(item.fields["customFields"]?.array ?? [], "document.number").isEmpty {
          TextField(t("证件号码", "Document number"), text: document("document.number"))
            .textInputAutocapitalization(.characters).autocorrectionDisabled().privacySensitive()
        } else {
          Text(t("证件号码", "Document number"))
          Spacer()
          Text("••••••••").foregroundStyle(.secondary)
        }
        if !IdentityDocument.value(item.fields["customFields"]?.array ?? [], "document.number").isEmpty {
          Button(revealing.contains("document.number") ? t("隐藏", "Hide") : t("显示", "Reveal")) {
            if revealing.contains("document.number") { revealing.remove("document.number") } else { revealing.insert("document.number") }
          }.buttonStyle(.borderless)
        }
      }
      TextField(t("签发机关", "Issued by"), text: document("document.issuer"))
      dateRow("document.issueDate", t("签发日期", "Issue date"))
      dateRow("document.expiryDate", t("有效期至", "Expires"))
    }
  }
  @ViewBuilder private func dateRow(_ id: String, _ label: String) -> some View {
    let fields = item.fields["customFields"]?.array ?? []
    let value = IdentityDocument.value(fields, id)
    if value.isEmpty {
      HStack {
        Text(label)
        Spacer()
        Button(t("添加日期", "Add date")) { setDocument(id, IdentityDocument.string(Date())) }
          .accessibilityLabel(t("添加", "Add") + label)
      }
    } else if IdentityDocument.date(value) != nil {
      HStack {
        DatePicker(label, selection: Binding(
          get: { IdentityDocument.date(IdentityDocument.value(item.fields["customFields"]?.array ?? [], id)) ?? Date() },
          set: { setDocument(id, IdentityDocument.string($0)) }), displayedComponents: .date)
          .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        Button { setDocument(id, "") } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
          .buttonStyle(.borderless).accessibilityLabel(t("清除", "Clear") + label)
      }
    } else {
      // A value written elsewhere that is not YYYY-MM-DD stays editable as text.
      TextField(label, text: document(id))
    }
  }
  private func document(_ id: String) -> Binding<String> {
    Binding(get: { IdentityDocument.value(item.fields["customFields"]?.array ?? [], id) }, set: { setDocument(id, $0) })
  }
  private func setDocument(_ id: String, _ value: String) {
    let fields = item.fields["customFields"]?.array ?? []
    // A number typed into an empty field stays visible while it is being entered.
    if id == "document.number" && IdentityDocument.value(fields, id).isEmpty { revealing.insert(id) }
    let updated = IdentityDocument.setting(fields, id, value)
    if updated != fields { item.fields["customFields"] = .array(updated) }
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
