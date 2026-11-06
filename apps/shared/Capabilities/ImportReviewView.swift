import SwiftUI
import UniformTypeIdentifiers

struct ImportReviewView: View {
  let perform: ([String: JSONValue]) async throws -> JSONValue
  let t: (String, String) -> String
  @Environment(\.dismiss) private var dismiss
  @State private var fileName = ""
  @State private var mappingExpanded = false
  @State private var picker = false
  @State private var source = ""
  @State private var format = "csv"
  @State private var preview: JSONValue = .object([:])
  @State private var mapping: [String: String] = [:]
  @State private var checkedMapping: [String: String] = [:]
  @State private var choices: [String: String] = [:]
  @State private var busy = false
  @State private var message = ""
  var body: some View {
    Group {
      #if os(macOS)
      macLayout
      #else
      Form {
      Section {
        Text(t("支持浏览器 CSV 和 1Password .1pux。原文件不会删除；重复条目默认跳过。", "Import browser CSV or 1Password .1pux. Source files are retained; duplicates are skipped by default."))
        Button(t("选择文件", "Choose file")) { picker = true }.disabled(busy)
        if !message.isEmpty { Text(message).accessibilityIdentifier("import.message") }
      }
      if format == "csv", let columns = preview.object["columns"]?.array, !columns.isEmpty {
        Section(t("字段映射", "Field mapping")) {
          ForEach(["title", "username", "password", "url", "notes"], id: \.self) { key in
            Picker(key, selection: Binding(get: { mapping[key] ?? "" }, set: { mapping[key] = $0 })) {
              Text(t("自动匹配", "Automatic")).tag("")
              ForEach(columns.compactMap { $0.string }, id: \.self) { Text($0).tag($0) }
            }
          }
          Button(t("重新预检", "Recheck mapping")) { Task { await inspect() } }.disabled(busy)
        }
      }
      if let rows = preview.object["rows"]?.array {
        Section(t("预检结果", "Preview")) {
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            let object = row.object
            let index = String(Int(object["index"]?.number ?? 0))
            let duplicate = !(object["duplicateIds"]?.array ?? []).isEmpty
            VStack(alignment: .leading) {
              Text(object["item"]?.object["title"]?.string ?? "")
              if duplicate { Text(t("检测到重复或同名记录", "Duplicate or same title detected")).foregroundStyle(.orange) }
              ForEach(object["warnings"]?.array.compactMap { $0.string } ?? [], id: \.self) { Text($0).font(.caption) }
              Toggle(t("作为新记录导入", "Import as new record"), isOn: Binding(get: { choices[index].map { $0 == "add" } ?? !duplicate }, set: { choices[index] = $0 ? "add" : "skip" }))
            }
          }
          ForEach(Array((preview.object["failures"]?.array ?? []).enumerated()), id: \.offset) { _, failure in
            Text("\(t("未导入行", "Rejected row")) \(Int(failure.object["row"]?.number ?? 0)): \(failure.object["reason"]?.string ?? "")").foregroundStyle(.red)
          }
          Button(t("确认导入", "Confirm import")) { Task { await commit() } }.disabled(busy || rows.isEmpty || mapping != checkedMapping)
        }
      }
      }
      #endif
    }
    .interactiveDismissDisabled(busy)
    .fileImporter(isPresented: $picker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
      Task {
        do {
          guard let url = try result.get().first else { return }
          let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
          let data = try Data(contentsOf: url)
          format = url.pathExtension.lowercased() == "1pux" ? "1pux" : "csv"
          fileName = url.lastPathComponent
          mappingExpanded = false
          source = data.base64EncodedString(); mapping = [:]; choices = [:]; await inspect()
        } catch { message = t("无法读取文件，原文件未修改", "Could not read file; source is unchanged") }
      }
    }
    .onDisappear { source = ""; fileName = ""; preview = .object([:]) }
  }
  #if os(macOS)
  private var rows: [JSONValue] { preview.object["rows"]?.array ?? [] }
  private var failures: [JSONValue] { preview.object["failures"]?.array ?? [] }
  private var selectedCount: Int { rows.filter { selected($0) }.count }
  private var mappingChanged: Bool { mapping != checkedMapping }
  private func selected(_ row: JSONValue) -> Bool {
    let index = String(Int(row.object["index"]?.number ?? 0))
    return choices[index].map { $0 == "add" } ?? (row.object["duplicateIds"]?.array ?? []).isEmpty
  }
  private func selection(_ row: JSONValue) -> Binding<Bool> {
    let index = String(Int(row.object["index"]?.number ?? 0))
    return Binding(get: { selected(row) }, set: { choices[index] = $0 ? "add" : "skip" })
  }
  private func fieldTitle(_ key: String) -> String {
    switch key {
    case "title": return t("标题", "Title")
    case "username": return t("用户名", "Username")
    case "password": return t("密码", "Password")
    case "url": return t("网站", "Website")
    default: return t("备注", "Notes")
    }
  }
  private var macLayout: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: "square.and.arrow.down").font(.system(size: 24)).foregroundStyle(.tint).padding(.top, 3)
        VStack(alignment: .leading, spacing: 5) {
          Text(t("导入资料", "Import your data")).font(.title2.bold())
          Text(t("从浏览器 CSV 或 1Password 迁入，确认预览后再写入资料库。", "Bring in browser CSV or 1Password data, then review before importing.")).foregroundStyle(.secondary)
        }
        Spacer()
        Button(t("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
      }.padding(24)
      Divider()
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 14) {
          Image(systemName: fileName.isEmpty ? "doc.badge.plus" : "doc.text").font(.system(size: 26)).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 5) {
            Text(fileName.isEmpty ? t("选择要导入的文件", "Choose a file to import") : fileName).font(.headline).lineLimit(1).truncationMode(.middle).help(fileName)
            HStack(spacing: 8) {
              if !fileName.isEmpty { Text(format == "1pux" ? "1Password · 1PUX" : "CSV").font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3).background(Color.primary.opacity(0.07), in: Capsule()) }
              Text(t("原文件保留 · 最多 64 MiB", "Source file retained · Up to 64 MiB")).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 8)
          if busy { ProgressView().controlSize(.small) }
          Button(fileName.isEmpty ? t("选择文件…", "Choose file…") : t("重新选择…", "Choose another…")) { picker = true }.disabled(busy)
        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.10)))
        if format == "csv", let columns = preview.object["columns"]?.array, !columns.isEmpty {
          DisclosureGroup(isExpanded: $mappingExpanded) {
            VStack(alignment: .leading, spacing: 12) {
              Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(["title", "username", "password", "url", "notes"], id: \.self) { key in
                  GridRow {
                    Text(fieldTitle(key)).foregroundStyle(.secondary)
                    Picker(fieldTitle(key), selection: Binding(get: { mapping[key] ?? "" }, set: { mapping[key] = $0 })) {
                      Text(t("自动匹配", "Automatic")).tag("")
                      ForEach(columns.map(\.string), id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().accessibilityLabel(fieldTitle(key)).frame(maxWidth: .infinity).disabled(busy)
                  }
                }
              }
              HStack {
                if mappingChanged { Label(t("字段已调整，请重新预检。", "Mapping changed. Recheck before importing."), systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button(t("重新预检", "Recheck mapping")) { Task { await inspect() } }.disabled(busy)
              }
            }.padding(.top, 12)
          } label: {
            HStack {
              Text(t("字段对应关系", "Column mapping")).font(.headline)
              Spacer()
              Text(mappingChanged ? t("待重新预检", "Recheck required") : t("自动匹配，可调整", "Automatic; customizable")).font(.caption).foregroundStyle(.secondary)
            }
          }.padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        }
        if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled).accessibilityIdentifier("import.message") }
      }.padding(.horizontal, 24).padding(.vertical, 18)
      Divider()
      if preview.object["rows"] != nil {
        VStack(spacing: 0) {
          HStack {
            Text(t("条目预览", "Entry preview")).font(.headline)
            Text("\(rows.count) \(t("条", "entries"))").foregroundStyle(.secondary)
            Spacer()
            Text(t("重复或同名条目默认跳过", "Duplicates and same-title entries are skipped by default")).font(.caption).foregroundStyle(.secondary)
          }.padding(.horizontal, 24).padding(.vertical, 14)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let object = row.object
                let duplicate = !(object["duplicateIds"]?.array ?? []).isEmpty
                HStack(alignment: .top, spacing: 12) {
                  Toggle(t("作为新记录导入", "Import as new record"), isOn: selection(row)).labelsHidden().toggleStyle(.checkbox).disabled(busy).accessibilityLabel((object["item"]?.object["title"]?.string ?? "") + " · " + t("作为新记录导入", "Import as new record"))
                  VStack(alignment: .leading, spacing: 5) {
                    Text(object["item"]?.object["title"]?.string ?? "").font(.body.weight(.medium)).textSelection(.enabled)
                    if duplicate { Label(t("重复或同名 · 勾选后将另存为新条目", "Duplicate or same title · Select to add a separate record"), systemImage: "doc.on.doc").font(.caption).foregroundStyle(.orange) }
                    ForEach(object["warnings"]?.array.map(\.string) ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                  }
                  Spacer(minLength: 0)
                }.padding(.vertical, 12)
                Divider()
              }
              ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                Label("\(t("未导入行", "Rejected row")) \(Int(failure.object["row"]?.number ?? 0)): \(failure.object["reason"]?.string ?? "")", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).padding(.vertical, 10)
              }
              if rows.isEmpty && failures.isEmpty { Text(t("文件中没有可导入的条目。", "This file contains no importable entries.")).foregroundStyle(.secondary).padding(.vertical, 24) }
            }.padding(.horizontal, 24)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36)).foregroundStyle(.tertiary)
          Text(busy ? t("正在检查文件…", "Checking your file…") : t("先选择文件，再检查导入内容", "Choose a file, then review its contents")).font(.headline)
          Text(t("支持浏览器 CSV 和 1Password .1pux。不会覆盖已有的同名条目。", "Supports browser CSV and 1Password .1pux. Existing same-title records will not be overwritten.")).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(t("已选择", "Selected")) \(selectedCount) / \(rows.count)").font(.headline)
          Text(t("仅导入勾选的条目；原文件不会删除。", "Only selected entries are imported; your source file is retained.")).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(t("确认导入", "Confirm import")) { Task { await commit() } }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busy || rows.isEmpty || selectedCount == 0 || mappingChanged || source.isEmpty)
      }.padding(.horizontal, 24).padding(.vertical, 18).background(Color.primary.opacity(0.025))
    }.frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 660)
  }
  #endif
  private func request(_ op: String) -> [String: JSONValue] {
    ["op": .string(op), "format": .string(format), "data": .string(source), "mapping": .object(mapping.filter { !$0.value.isEmpty }.mapValues(JSONValue.string)), "choices": .object(choices.mapValues(JSONValue.string))]
  }
  @MainActor private func inspect() async {
    guard !busy, !source.isEmpty else { return }
    busy = true; defer { busy = false }
    let submitted = mapping
    do { preview = try await perform(request("import-preview")); checkedMapping = submitted; message = ""; choices = [:] }
    catch { preview = .object([:]); message = t("预检失败；未更改资料库", "Preview failed; vault unchanged") }
  }
  @MainActor private func commit() async {
    guard !busy, !source.isEmpty, mapping == checkedMapping else { return }
    busy = true; defer { busy = false }
    do { let result = try await perform(request("import-commit")).object; message = "\(t("已导入", "Imported")): \(Int(result["added"]?.number ?? 0)); \(t("跳过", "Skipped")): \(Int(result["skipped"]?.number ?? 0))"; source = ""; fileName = ""; preview = .object([:]) }
    catch { message = t("导入失败；原有数据已保留", "Import failed; existing data retained") }
  }
}
