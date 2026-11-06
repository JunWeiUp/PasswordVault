import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct MobileRichNoteEditor: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let original: VaultItem
  @State private var draft: VaultItem
  @State private var session: MobileNoteSession?
  @State private var picker = false
  @State private var exporting = false
  @State private var exportDocument: MobileNoteFile?
  @State private var exportName = "Note.md"
  @State private var error = ""
  @State private var saving = false
  @State private var discard = false
  init(item: VaultItem) { original = item; _draft = State(initialValue: item) }
  var body: some View {
    NavigationStack {
      VStack(spacing: 8) {
        TextField(store.t("标题", "Title"), text: Binding(get: { draft.title }, set: { draft.title = $0; store.pendingDraft = draft })).font(.title2).padding(.horizontal).disabled(!store.canEdit(draft))
        if !error.isEmpty { Text(error).foregroundStyle(.orange).font(.caption).padding(.horizontal) }
        MobileNoteSurface(item: draft, store: store, connected: { value in
          session = value
          value.changed = { item in draft = item; store.pendingDraft = item; store.activity() }
          value.failed = { error = store.t("编辑器操作未完成，最近确认的草稿已保留。", "Editor operation incomplete; last confirmed draft retained.") }
          value.chooseFile = { picker = true }
          value.exportFile = { data, name in exportDocument = MobileNoteFile(data: data); exportName = (name as NSString).lastPathComponent; exporting = true }
          if store.canEdit(draft) { store.pendingDraft = draft; store.captureRichDraft = { value.capture(closing: true) } }
        })
      }
      .navigationTitle(store.t("图文笔记", "Rich note"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(store.t("取消", "Cancel")) { discard = true }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button(store.t("保存", "Save")) {
            saving = true
            Task {
              defer { saving = false }
              guard let value = await session?.capture(closing: false).value else { error = store.t("无法取得完整草稿，请重试。", "Could not capture full draft; retry."); return }
              var latest = value; latest.title = draft.title
              if await store.save(latest) { store.captureRichDraft = nil; store.discardDraft(); _ = session?.capture(closing: true); dismiss() }
            }
          }.disabled(!store.canEdit(draft) || saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .interactiveDismissDisabled()
      .confirmationDialog(store.t("放弃未保存的修改？", "Discard unsaved changes?"), isPresented: $discard) {
        Button(store.t("放弃修改", "Discard changes"), role: .destructive) { store.captureRichDraft = nil; store.discardDraft(); session?.discard(); dismiss() }
      }
      .fileImporter(isPresented: $picker, allowedContentTypes: [.data]) { result in
        Task {
          guard let session else { return }
          do {
            let url = try result.get(); let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 25 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url)
            await session.importChosen(data: data, name: url.lastPathComponent, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
          } catch { await session.uploadError() }
        }
      }
      .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .data, defaultFilename: exportName) { result in
        if case .failure = result { error = store.t("文件未导出，原件已保留。", "Export failed; original retained.") }
        exportDocument = nil
      }
    }
  }
}
private struct MobileNoteFile: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  let data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
private struct MobileNoteSurface: UIViewRepresentable {
  let item: VaultItem
  let store: MobileVaultStore
  let connected: (MobileNoteSession) -> Void
  func makeCoordinator() -> MobileNoteSession { MobileNoteSession(item: item, store: store) }
  func makeUIView(context: Context) -> WKWebView { let session = context.coordinator; connected(session); session.load(); return session.webView }
  func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.item.title = item.title }
  static func dismantleUIView(_ view: WKWebView, coordinator: MobileNoteSession) { _ = coordinator.capture(closing: true) }
}

@MainActor
final class MobileNoteSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let token = UUID().uuidString.lowercased()
  var item: VaultItem
  weak var store: MobileVaultStore?
  let webView: WKWebView
  let resources = MobileNoteResources()
  var changed: ((VaultItem) -> Void)?
  var failed: (() -> Void)?
  var chooseFile: (() -> Void)?
  var exportFile: ((Data, String) -> Void)?
  private var ready = false
  private(set) var closing = false
  private var closeTask: Task<VaultItem?, Never>?
  private var revision = 0
  private var request: String?
  private var uploads: [String: (String, String, Int, Data)] = [:]
  private var cancelled = Set<String>()
  init(item: VaultItem, store: MobileVaultStore) {
    self.item = item; self.store = store
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.setURLSchemeHandler(resources, forURLScheme: "pvnote")
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    config.userContentController.add(MobileNoteWeakHandler(self), name: "noteEditor")
    webView.navigationDelegate = self; resources.owner = self
  }
  func load() {
    guard let url = Bundle.main.url(forResource: "NoteEditor", withExtension: "html"), let html = try? String(contentsOf: url, encoding: .utf8) else { failed?(); return }
    webView.loadHTMLString(html.replacingOccurrences(of: "</style>", with: "html,body{overflow:auto!important;min-height:100%}#editor{padding:8px}input,select,textarea{font-size:16px}</style>"), baseURL: nil)
  }
  func evaluate(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any {
    try await withCheckedThrowingContinuation { continuation in
      var finished = false
      webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
        guard !finished else { return }; finished = true; continuation.resume(with: result)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { guard !finished else { return }; finished = true; continuation.resume(throwing: URLError(.timedOut)) }
    }
  }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, !closing, store?.unlocked == true, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
    if kind == "ready", !ready {
      ready = true
      Task {
        do { _ = try await evaluate("return window.pvEditor.configure(options)", ["options": ["sequence":0,"format":item.string("noteFormat"),"token":token,"source":item.editorSource,"expectedRevision":0,"editable":store?.canEdit(item) == true,"editing":true,"chinese":store?.chinese == true]]) }
        catch { failed?() }
      }
      return
    }
    guard ready, body["token"] as? String == token else { return }
    switch kind {
    case "change":
      guard store?.canEdit(item) == true, let source = body["source"] as? String, source.utf8.count <= 16 * 1024 * 1024, let next = body["revision"] as? Int, next >= revision else { return }
      revision = next; item.editorSource = source; changed?(item)
    case "chooseFile":
      guard store?.canEdit(item) == true, let value = body["request"] as? String else { return }
      request = value
      guard store?.items.contains(where: { $0.id == item.id }) == true else { Task { await uploadError(message: "请先保存笔记再添加附件 / Save this note before attaching files") }; return }
      chooseFile?()
    case "uploadStart":
      guard store?.canEdit(item) == true, let id = body["request"] as? String, let name = body["name"] as? String, let size = body["size"] as? Int, (0...25*1024*1024).contains(size), uploads.count < 4 else { return }
      uploads[id] = (name, body["mime"] as? String ?? "application/octet-stream", size, Data())
    case "uploadChunk":
      guard let id = body["request"] as? String, var upload = uploads[id], let encoded = body["data"] as? String, encoded.count <= 300_000, let bytes = Data(base64Encoded: encoded), upload.3.count + bytes.count <= upload.2 else { return }
      upload.3.append(bytes); uploads[id] = upload
    case "uploadFinish":
      guard let id = body["request"] as? String, let upload = uploads.removeValue(forKey: id), upload.3.count == upload.2 else { return }
      Task { await importData(request: id, data: upload.3, name: upload.0, mime: upload.1) }
    case "cancelUpload": if let id = body["request"] as? String { cancelled.insert(id); uploads.removeValue(forKey: id) }
    case "discardAttachment": if let id = body["id"] as? String, let core = store?.core { Task { try? await core.discardAttachment(noteID: item.id, id: id) } }
    case "saveAttachment":
      if let id = body["id"] as? String, let name = body["name"] as? String, let core = store?.core {
        Task { do { let data = try await core.readAttachment(noteID: item.id, id: id); guard !closing, store?.unlocked == true else { return }; exportFile?(data, name) } catch { failed?() } }
      }
    case "exportMarkdown": if let markdown = body["markdown"] as? String { exportFile?(Data(markdown.utf8), "Note.md") }
    case "wheel":
      if let delta = body["deltaY"] as? Double, delta.isFinite {
        let scroll = webView.scrollView
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(max(0, scroll.contentSize.height - scroll.bounds.height), max(0, scroll.contentOffset.y + CGFloat(delta)))), animated: false)
      }
    case "failure": failed?()
    default: break
    }
  }
  func importChosen(data: Data, name: String, mime: String) async { guard let request else { return }; await importData(request: request, data: data, name: name, mime: mime) }
  private func importData(request: String, data: Data, name: String, mime: String) async {
    guard !closing, store?.unlocked == true, store?.canEdit(item) == true, !cancelled.contains(request), let core = store?.core else { return }
    do {
      let actual = mime.hasPrefix("image/") && UIImage(data: data) == nil ? "application/octet-stream" : mime
      let meta = try await core.importAttachment(noteID: item.id, name: name, mime: actual, data: data)
      guard !closing, store?.unlocked == true, !cancelled.contains(request) else { try? await core.discardAttachment(noteID: item.id, id: meta.object["id"]?.string ?? ""); return }
      let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta))
      _ = try await evaluate("return window.pvEditor.attachment(request, meta)", ["request":request,"meta":object])
    } catch { await uploadError(request: request) }
  }
  func uploadError(request override: String? = nil, message: String = "附件导入失败，请重试 / Attachment import failed; retry") async {
    guard let request = override ?? request, !closing else { return }
    _ = try? await evaluate("window.pvEditor.uploadError(request,message)", ["request":request,"message":message])
  }
  func capture(closing close: Bool) -> Task<VaultItem?, Never> {
    if let closeTask { return closeTask }
    if close { closing = true; webView.isHidden = true; uploads.removeAll() }
    let task = Task<VaultItem?, Never> { [self] in
      defer { if close { clear() } }
      guard ready else { return item }
      do {
        guard let result = try await evaluate("return await window.pvEditor.snapshot(close)", ["close":close]) as? [String:Any], let source = result["source"] as? String else { failed?(); return nil }
        item.editorSource = source
        return item
      } catch { failed?(); return nil }
    }
    if close { closeTask = task }; return task
  }
  func discard() { closing = true; closeTask = Task { nil }; clear() }
  private func clear() { ready = false; webView.configuration.userContentController.removeScriptMessageHandler(forName: "noteEditor"); resources.cancelAll(); webView.navigationDelegate = nil; webView.stopLoading(); webView.loadHTMLString("", baseURL: nil); changed = nil; exportFile = nil; chooseFile = nil }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed?() }
}
private final class MobileNoteWeakHandler: NSObject, WKScriptMessageHandler {
  weak var owner: MobileNoteSession?
  init(_ owner: MobileNoteSession) { self.owner = owner }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { owner?.userContentController(controller, didReceive: message) }
}
@MainActor
final class MobileNoteResources: NSObject, WKURLSchemeHandler {
  weak var owner: MobileNoteSession?
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    let key = ObjectIdentifier(urlSchemeTask)
    tasks[key] = Task {
      do {
        guard let owner, !owner.closing, owner.store?.unlocked == true, let core = owner.store?.core, let url = urlSchemeTask.request.url, url.scheme == "pvnote", url.host == owner.token else { throw URLError(.noPermissionsToReadFile) }
        let id = String(url.path.dropFirst()); guard !id.isEmpty, !id.contains("/"), url.query == nil else { throw URLError(.badURL) }
        let data = try await core.readAttachment(noteID: owner.item.id, id: id)
        guard !Task.isCancelled, !owner.closing, owner.store?.unlocked == true else { return }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: UIImage(data: data) == nil ? "application/octet-stream" : "image/png", expectedContentLength: data.count, textEncodingName: nil)); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
      } catch { if !Task.isCancelled { urlSchemeTask.didFailWithError(error) } }
      tasks.removeValue(forKey: key)
    }
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
  func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}
