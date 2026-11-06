import SwiftUI
import Foundation
import UniformTypeIdentifiers

private final class RangeRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct SecurityCenterView: View {
  let items: [VaultItem]
  let perform: ([String: JSONValue]) async throws -> JSONValue
  let t: (String, String) -> String
  var openItem: (String) -> Void = { _ in }
  @State private var catalogPicker = false
  @State private var report: JSONValue = .object([:])
  @State private var enabled = false
  @State private var working = false
  @State private var message = ""
  @State private var breach: [String: String] = [:]
  @State private var checkTask: Task<Void, Never>?
  var body: some View {
    Form {
      Section(t("本地检查", "Local checks")) {
        Button(t("导入更新目录", "Import updated catalog")) { catalogPicker = true }
        Button(t("重新检查", "Recheck")) { Task { await refresh() } }
        Text(t("网站目录覆盖有限；未列入的网站未检查。建议不代表账号已启用相应验证方式。", "Site coverage is limited. Unlisted sites are not checked. Suggestions do not verify your account configuration."))
        if let updated = report.object["catalogUpdatedAt"]?.string { Text("\(t("目录更新", "Catalog updated")): \(updated)") }
        DisclosureGroup(t("数据来源与许可", "Data sources and licenses")) {
          Text(report.object["catalogLicense"]?.string ?? "")
          ForEach(Array((report.object["catalogSources"]?.array ?? []).enumerated()), id: \.offset) { _, source in
            if let link = URL(string: source.object["url"]?.string ?? "") { Link(source.object["name"]?.string ?? "Source", destination: link) }
          }
          Text(report.object["catalogLicenseText"]?.string ?? "").font(.caption).textSelection(.enabled)
        }
        ForEach(Array((report.object["findings"]?.array ?? []).enumerated()), id: \.offset) { _, finding in
          let object = finding.object
          VStack(alignment: .leading) {
            Button("\(object["title"]?.string ?? object["id"]?.string ?? "") · \(findingTitle(object["kind"]?.string ?? ""))") { openItem(object["id"]?.string ?? "") }
            let detail = findingDetails(object)
            if !detail.isEmpty { Text(detail).font(.callout) }
            if let source = object["source"]?.string, let url = URL(string: source) { Link(t("查看依据", "View source"), destination: url) }
            if let incident = object["incident"]?.object, let source = incident["source"]?.string, let url = URL(string: source) { Link(incident["title"]?.string ?? t("事件依据", "Incident source"), destination: url) }
            Button(object["ignored"]?.bool == true ? t("恢复提醒", "Restore finding") : t("忽略此项", "Ignore finding")) {
              Task { do { _ = try await perform(["op": .string("security-ignore"), "key": object["key"] ?? .string(""), "ignored": .bool(!(object["ignored"]?.bool ?? false))]); await refresh() } catch { message = t("无法保存设置", "Could not save setting") } }
            }
          }.opacity(object["ignored"]?.bool == true ? 0.5 : 1)
        }
      }
      Section(t("泄露密码检查（可选）", "Exposed passwords (optional)")) {
        Toggle(t("允许本次联网检查", "Allow network check for this session"), isOn: $enabled)
        Text(t("仅向 Have I Been Pwned 发送 SHA-1 前 5 位；不会发送密码、完整哈希、账号或站点。未检查与网络失败均不表示安全。", "Only the first 5 SHA-1 characters go to Have I Been Pwned. No passwords, full hashes, accounts or sites are sent. Unchecked and failed checks do not mean safe."))
        Button(t("检查 / 重新检查", "Check / recheck")) { checkTask = Task { await check() } }.disabled(!enabled || working)
        if working { ProgressView() }
        ForEach(items.filter { $0.type == "password" && !$0.isDeleted }) { item in
          Text("\(item.title): \(breach[item.id] ?? t("未检查", "Not checked"))")
        }
      }
      if !message.isEmpty { Text(message).foregroundStyle(.red) }
    }.task { await refresh() }
      .onChange(of: enabled) { value in if !value { checkTask?.cancel(); breach = [:] } }
      .onDisappear { checkTask?.cancel(); breach = [:] }
      .fileImporter(isPresented: $catalogPicker, allowedContentTypes: [.json]) { result in
        Task {
          do {
            let url = try result.get(); let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            _ = try await perform(["op": .string("security-catalog"), "catalog": catalog]); await refresh()
          } catch { message = t("目录导入失败，已保留原目录", "Catalog import failed; previous catalog retained") }
        }
      }
  }
  private func findingTitle(_ kind: String) -> String {
    switch kind {
    case "passwordHealth": return t("密码需要检查", "Password needs attention")
    case "twoFactorAvailable": return t("可启用双重验证", "Two-factor authentication available")
    case "passkeyAvailable": return t("支持通行密钥", "Passkey available")
    case "siteIncident": return t("网站安全事件", "Website security incident")
    case "duplicateEntry": return t("重复条目", "Duplicate entry")
    default: return t("其他安全提醒", "Other security finding")
    }
  }
  private func findingDetails(_ finding: [String: JSONValue]) -> String {
    guard finding["kind"]?.string == "passwordHealth" else { return "" }
    return [
      finding["weak"]?.bool == true ? t("密码较弱", "Weak password") : "",
      finding["reused"]?.bool == true ? t("密码重复使用", "Reused password") : "",
      finding["expired"]?.bool == true ? t("密码已超过设置的有效期", "Password exceeds its configured age") : "",
    ].filter { !$0.isEmpty }.joined(separator: " · ")
  }
  @MainActor private func refresh() async {
    do { report = try await perform(["op": .string("security-audit")]); message = "" }
    catch { message = t("检查未完成", "Check incomplete") }
  }
  @MainActor private func check() async {
    working = true; breach = [:]; defer { working = false }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config, delegate: RangeRedirectGuard(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    for item in items.filter({ $0.type == "password" && !$0.isDeleted }) {
      if Task.isCancelled || !enabled { return }
      do {
        var values = [item.password]
        values += (item.fields["accounts"]?.array ?? []).map { $0.object["password"]?.string ?? "" }
        var occurrences = 0
        for value in Set(values).filter({ !$0.isEmpty }) {
          try Task.checkCancellation()
          let parts = try await perform(["op": .string("breach-request"), "password": .string(value)]).object
          guard let prefix = parts["prefix"]?.string, prefix.count == 5, prefix.allSatisfy({ $0.isHexDigit }), let suffix = parts["suffix"] else { throw URLError(.badServerResponse) }
          var request = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!)
          request.setValue("true", forHTTPHeaderField: "Add-Padding"); request.timeoutInterval = 20
          let (data, response) = try await session.data(for: request)
          guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
          let result = try await perform(["op": .string("breach-response"), "suffix": suffix, "response": .string(text)])
          occurrences += Int(result.object["count"]?.number ?? 0)
        }
        try Task.checkCancellation()
        breach[item.id] = values.allSatisfy({ $0.isEmpty }) ? t("无密码可检查", "No password to check") : (occurrences > 0 ? t("发现泄露记录，请更换密码", "Exposed password found; change it") : t("本次查询未发现记录", "Not found in this query"))
      } catch {
        if Task.isCancelled { return }
        breach[item.id] = t("检查未完成，请重试", "Check incomplete; retry")
      }
    }
  }
}
