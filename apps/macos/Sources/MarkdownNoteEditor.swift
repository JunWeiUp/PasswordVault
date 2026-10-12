import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
protocol NoteEditorLease: AnyObject {
  var id: UUID { get }
  var itemID: String { get }
  var source: String { get }
  var isClosing: Bool { get }
  func capture(closing: Bool) -> Task<Result<String, Error>, Never>
}

enum NoteEditorError: Error { case unavailable, timeout, invalidResponse }

struct MarkdownNoteEditor: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  let editing: Bool
  let beginEditing: () -> Void
  @State private var height: CGFloat = 360
  @State private var failed = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if failed {
        Label(
          store.t(
            "编辑器未能加载。已保留最近确认的内容；请重新打开笔记后检查。",
            "The editor could not load. Last confirmed content is preserved; reopen and check the note."
          ), systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange).font(.callout)
      }
      MarkdownEditorSurface(
        item: item, editing: editing, beginEditing: beginEditing, height: $height, failed: $failed
      )
      .frame(height: height)
    }
  }
}

private struct MarkdownEditorSurface: NSViewRepresentable {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  let editing: Bool
  let beginEditing: () -> Void
  @Binding var height: CGFloat
  @Binding var failed: Bool
  func makeCoordinator() -> NoteEditorSession {
    NoteEditorSession(itemID: item.id, source: item.editorSource, store: store)
  }
  func makeNSView(context: Context) -> NoteWebView {
    let session = context.coordinator
    session.heightChanged = { if abs(height - $0) > 0.5 { height = $0 } }
    session.failed = { failed = true }
    session.beginEditing = beginEditing
    session.update(
      source: item.editorSource, editable: store.canEdit(item), editing: editing,
      chinese: store.chinese)
    session.load()
    return session.webView
  }
  func updateNSView(_ view: NoteWebView, context: Context) {
    context.coordinator.beginEditing = beginEditing
    context.coordinator.update(
      source: item.editorSource, editable: store.canEdit(item), editing: editing,
      chinese: store.chinese)
  }
  static func dismantleNSView(_ view: NoteWebView, coordinator: NoteEditorSession) {
    coordinator.heightChanged = nil
    coordinator.failed = nil
    coordinator.beginEditing = nil
    coordinator.store?.retireNoteEditor(coordinator)
  }
}

@MainActor
final class NoteEditorSession: NSObject, NoteEditorLease, WKScriptMessageHandler,
  WKNavigationDelegate
{
  let id = UUID()
  let itemID: String
  private(set) var source: String
  private(set) var isClosing = false
  weak var store: AppStore?
  var heightChanged: ((CGFloat) -> Void)?
  var failed: (() -> Void)?
  var beginEditing: (() -> Void)?
  private(set) var revision = 0
  private var editable = false, editing = false, chinese = true
  private var ready = false, registered = false
  private var closeTask: Task<Result<String, Error>, Never>?
  private var linkURL: URL?
  private var configurationSequence = 0
  private var focusRequested = false
  private var lastHeight: CGFloat = 0
  private var scrollGeneration = 0
  private var latestLayout = 0
  private var uploadBuffers: [String: (String, String, Int, Data)] = [:]
  private var cancelledUploads: Set<String> = []
  let resources = NoteResourceHandler()

  let webView: NoteWebView

  init(itemID: String, source: String, store: AppStore) {
    self.itemID = itemID
    self.source = source
    self.store = store
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.suppressesIncrementalRendering = true
    config.setURLSchemeHandler(resources, forURLScheme: "pvnote")
    webView = NoteWebView(frame: .zero, configuration: config)
    super.init()
    config.userContentController.add(WeakNoteMessageHandler(self), name: "noteEditor")
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    webView.setValue(false, forKey: "drawsBackground")
    webView.setAccessibilityIdentifier("note.markdown.editor")
    webView.noteSession = self
    resources.session = self
  }
  func cancelFocus() { focusRequested = false }
  func focusBody() {
    guard editable, !isClosing else { return }
    focusRequested = true
    editing = true
    if ready && registered { configure(source) }
  }
  func load() {
    guard let url = Bundle.main.url(forResource: "NoteEditor", withExtension: "html"),
      let html = try? String(contentsOf: url, encoding: .utf8)
    else {
      failed?()
      return
    }
    // Only static editor code is loaded here. Note text is passed as an argument
    // after initialization; it is never interpolated into HTML or written to disk.
    webView.loadHTMLString(html, baseURL: nil)
  }
  func update(source incoming: String, editable: Bool, editing: Bool, chinese: Bool) {
    guard !isClosing else { return }
    let changed =
      source != incoming || self.editable != editable || self.editing != editing
      || self.chinese != chinese
    self.editable = editable
    self.editing = editing
    self.chinese = chinese
    if !registered { source = incoming }
    if ready && registered && changed { configure(incoming) }
  }
  private func configure(_ incoming: String) {
    guard !isClosing, ready, registered else { return }
    let expected = revision
    configurationSequence += 1
    let options: [String: Any] = [
      "sequence": configurationSequence,
      "format": store?.items.first(where: { $0.id == itemID })?.string("noteFormat") ?? "markdown",
      "token": id.uuidString, "source": incoming, "expectedRevision": expected,
      "editable": editable, "editing": editing, "chinese": chinese,
    ]
    let sequence = configurationSequence
    Task { [weak self] in
      guard let self else { return }
      do {
        let response =
          try await evaluate(
            "return window.pvEditor.configure(options)", arguments: ["options": options])
          as? [String: Any]
        if response?["accepted"] as? Bool == true, revision == expected, !isClosing {
          source = incoming
          if focusRequested && sequence == configurationSequence {
            focusRequested = false
            webView.window?.makeFirstResponder(webView)
            _ = try? await evaluate("window.pvEditor.refocus()")
          }
        } else if !isClosing, sequence == configurationSequence, revision != expected {
          configure(source)
        }
      } catch { if !isClosing { failed?() } }
    }
  }
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame, !isClosing,
      let body = message.body as? [String: Any], let kind = body["kind"] as? String
    else { return }
    if kind == "ready" {
      guard !ready else { return }
      ready = true
      Task { [weak self] in
        guard let self, let store, let latest = await store.prepareNoteEditor(self), !isClosing
        else { return }
        registered = true
        source = latest
        configure(latest)
      }
      return
    }
    if kind == "failure" {
      failed?()
      return
    }
    guard registered, body["token"] as? String == id.uuidString else { return }
    switch kind {
    case "change":
      guard editable, let text = body["source"] as? String, let number = body["revision"] as? Int,
        number >= revision
      else { return }
      revision = number
      if store?.receiveNoteEditorChange(self, text: text) == true { source = text }
    case "editing":
      guard editable else { return }
      editing = true
      beginEditing?()
    case "height":
      if let value = body["height"] as? Double, value.isFinite {
        let newHeight = CGFloat(min(1_000_000, max(360, value)))
        latestLayout = body["layoutID"] as? Int ?? latestLayout
        if abs(lastHeight - newHeight) > 0.5 {
          lastHeight = newHeight
          heightChanged?(newHeight)
        }
      }
    case "wheel":
      guard store?.unlocked == true, let delta = body["deltaY"] as? Double,
        delta.isFinite, let mode = body["deltaMode"] as? Int, (0...2).contains(mode),
        let scroll = webView.enclosingScrollView
      else { return }
      // Cancel queued caret scrolling so a user's gesture wins over stale layout.
      scrollGeneration += 1
      let clip = scroll.contentView
      let scale: CGFloat = mode == 1 ? 24 : (mode == 2 ? clip.bounds.height : 1)
      var destination = clip.bounds
      let direction: CGFloat = scroll.documentView?.isFlipped == false ? -1 : 1
      destination.origin.y += CGFloat(max(-1_000_000, min(1_000_000, delta))) * scale * direction
      clip.scroll(to: clip.constrainBoundsRect(destination).origin)
      scroll.reflectScrolledClipView(clip)
    case "caret":
      guard editing, editable, let x = body["x"] as? Double, let y = body["y"] as? Double,
        let height = body["height"] as? Double, x.isFinite, y.isFinite, height.isFinite
      else { return }
      let layout = body["layoutID"] as? Int ?? latestLayout
      scrollGeneration += 1
      let generation = scrollGeneration
      // Layout first, scroll second. Scrolling must never change the first responder.
      DispatchQueue.main.async { [weak self] in
        guard let self, !isClosing, editing, generation == scrollGeneration, layout >= latestLayout,
          let responder = webView.window?.firstResponder as? NSView,
          responder === webView || responder.isDescendant(of: webView)
        else { return }
        webView.superview?.layoutSubtreeIfNeeded()
        let top = webView.isFlipped ? y - 16 : webView.bounds.height - y - height - 16
        if let scroll = webView.enclosingScrollView {
          let rect = webView.convert(
            NSRect(x: max(0, x - 8), y: max(0, top), width: 24, height: height + 32),
            to: scroll.contentView)
          _ = scroll.contentView.scrollToVisible(rect)
          scroll.reflectScrolledClipView(scroll.contentView)
        }
      }
    case "chooseFile":
      guard editable, let request = body["request"] as? String else { return }
      chooseFile(request: request, images: body["images"] as? Bool == true)
    case "uploadStart":
      guard editable, let request = body["request"] as? String, let name = body["name"] as? String,
        let size = body["size"] as? Int, size >= 0, size <= 25 * 1024 * 1024,
        uploadBuffers.count < 4
      else { return }
      uploadBuffers[request] = (
        name, body["mime"] as? String ?? "application/octet-stream", size, Data()
      )
    case "uploadChunk":
      guard let request = body["request"] as? String, var upload = uploadBuffers[request],
        let encoded = body["data"] as? String, encoded.count <= 300_000,
        let data = Data(base64Encoded: encoded), upload.3.count + data.count <= upload.2
      else { return }
      upload.3.append(data)
      uploadBuffers[request] = upload
    case "uploadFinish":
      guard let request = body["request"] as? String,
        let upload = uploadBuffers.removeValue(forKey: request), upload.3.count == upload.2
      else { return }
      importFile(request: request, name: upload.0, mime: upload.1, data: upload.3)
    case "cancelUpload":
      if let request = body["request"] as? String {
        cancelledUploads.insert(request)
        uploadBuffers.removeValue(forKey: request)
      }
    case "discardAttachment":
      if let id = body["id"] as? String, let core = store?.core {
        Task { try? await core.discardAttachment(noteID: itemID, id: id) }
      }
    case "saveAttachment":
      if let id = body["id"] as? String, let name = body["name"] as? String {
        saveAttachment(id: id, name: name)
      }
    case "exportMarkdown":
      if let markdown = body["markdown"] as? String { exportMarkdown(markdown) }
    case "state":
      webView.canUndoNote = editing && editable && body["undo"] as? Bool == true
      webView.canRedoNote = editing && editable && body["redo"] as? Bool == true
    case "link":
      guard let raw = body["url"] as? String, let url = URL(string: raw),
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
        let x = body["x"] as? Double, let y = body["y"] as? Double
      else { return }
      linkURL = url
      let menu = NSMenu()
      let open = NSMenuItem(
        title: chinese ? "打开链接" : "Open link", action: #selector(openLink), keyEquivalent: "")
      open.target = self
      menu.addItem(open)
      menu.popUp(
        positioning: nil, at: NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y),
        in: webView)
    default: break
    }
  }
  @objc private func openLink() { if !isClosing, let linkURL { NSWorkspace.shared.open(linkURL) } }
  func command(_ action: String) {
    guard editable, !isClosing, registered else { return }
    Task {
      _ = try? await evaluate("window.pvEditor.command(action)", arguments: ["action": action])
    }
  }
  func capture(closing: Bool) -> Task<Result<String, Error>, Never> {
    if let closeTask { return closeTask }
    if closing {
      isClosing = true
      webView.isHidden = true
      scrollGeneration += 1
      uploadBuffers.removeAll()
      resources.cancelAll()
    }
    let task = Task<Result<String, Error>, Never> { [self] in
      defer { if closing { clear() } }
      guard ready && registered else { return .success(source) }
      do {
        guard
          let result = try await evaluate(
            "return await window.pvEditor.snapshot(close)", arguments: ["close": closing])
            as? [String: Any],
          let text = result["source"] as? String
        else { throw NoteEditorError.invalidResponse }
        return .success(text)
      } catch { return .failure(error) }
    }
    if closing { closeTask = task }
    return task
  }
  private func clear() {
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "noteEditor")
    webView.navigationDelegate = nil
    webView.noteSession = nil
    resources.session = nil
    webView.stopLoading()
    webView.loadHTMLString("", baseURL: nil)
    // Keep the acknowledged source and completed close task until the lease is
    // released. Retirement and locking can consume the same snapshot concurrently.
    linkURL = nil
    ready = false
    registered = false
  }
  func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any {
    try await withCheckedThrowingContinuation { continuation in
      var finished = false
      webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
        guard !finished else { return }
        finished = true
        continuation.resume(with: result)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        guard !finished else { return }
        finished = true
        continuation.resume(throwing: NoteEditorError.timeout)
      }
    }
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(
      navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed?() }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failed?()
  }
}

@MainActor
private final class WeakNoteMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: NoteEditorSession?
  init(_ target: NoteEditorSession) { self.target = target }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

final class NoteWebView: WKWebView {
  weak var noteSession: NoteEditorSession?
  var canUndoNote = false, canRedoNote = false
  @objc func undo(_ sender: Any?) { noteSession?.command("undo") }
  @objc func redo(_ sender: Any?) { noteSession?.command("redo") }
  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(undo(_:)) { return canUndoNote }
    if item.action == #selector(redo(_:)) { return canRedoNote }
    return super.validateUserInterfaceItem(item)
  }
}

extension NoteEditorSession {
  private func chooseFile(request: String, images: Bool) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if images { panel.allowedContentTypes = [.png, .jpeg, .gif, .webP] }
    panel.begin { [weak self] response in
      guard let self, !isClosing, editable, store?.unlocked == true else { return }
      guard response == .OK, let url = panel.url else {
        Task {
          _ = try? await self.evaluate(
            "window.pvEditor.cancelUpload(request)", arguments: ["request": request])
        }
        return
      }
      do {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 25 * 1024 * 1024 else { throw NoteEditorError.invalidResponse }
        let data = try Data(contentsOf: url)
        let mime =
          UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
          ?? "application/octet-stream"
        importFile(request: request, name: url.lastPathComponent, mime: mime, data: data)
      } catch { uploadFailed(request) }
    }
  }
  private func importFile(request: String, name: String, mime: String, data: Data) {
    guard !isClosing, editable, let store, store.unlocked, let core = store.core,
      let item = store.items.first(where: { $0.id == itemID }), store.canEdit(item)
    else { return }
    Task {
      do {
        _ = try? await evaluate(
          "window.pvEditor.uploadProgress(request, 90)", arguments: ["request": request])
        guard !isClosing, !cancelledUploads.contains(request) else { return }
        let actualMIME: String
        if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime),
          NSImage(data: data) != nil
        {
          actualMIME = mime
        } else {
          actualMIME = "application/octet-stream"
        }
        let meta = try await core.importAttachment(
          noteID: itemID, name: name, mime: actualMIME, data: data)
        let id = meta.object["id"]?.string ?? ""
        guard !isClosing, store.unlocked, !cancelledUploads.contains(request),
          let latest = store.items.first(where: { $0.id == itemID }), store.canEdit(latest)
        else {
          try? await core.discardAttachment(noteID: itemID, id: id)
          return
        }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta))
        _ = try await evaluate(
          "return window.pvEditor.attachment(request, meta)",
          arguments: ["request": request, "meta": object])
      } catch { if !isClosing { uploadFailed(request) } }
    }
  }
  private func uploadFailed(_ request: String) {
    Task {
      _ = try? await evaluate(
        "window.pvEditor.uploadError(request, message)",
        arguments: [
          "request": request,
          "message": chinese
            ? "导入未完成。单文件上限 25 MiB，每篇合计 250 MiB；请检查文件后重试。"
            : "Import failed. Limit: 25 MiB per file, 250 MiB per note. Check the file and retry.",
        ])
    }
  }
  private func saveAttachment(id: String, name: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (name as NSString).lastPathComponent
    panel.message =
      chinese ? "另存的文件不再受资料库加密保护。" : "The saved file will be outside vault encryption."
    panel.begin { [weak self] response in
      guard let self, response == .OK, let url = panel.url, !isClosing, store?.unlocked == true,
        let core = store?.core
      else { return }
      Task {
        do {
          let data = try await core.readAttachment(noteID: self.itemID, id: id)
          guard !self.isClosing, self.store?.unlocked == true else { return }
          try data.write(to: url, options: .atomic)
        } catch {
          self.store?.error =
            self.chinese
            ? "附件未能导出，原件已保留。" : "Could not export the attachment. The original was preserved."
        }
      }
    }
  }
  private func exportMarkdown(_ markdown: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Note.md"
    panel.message =
      chinese
      ? "Markdown 不保留颜色、对齐和合并单元格。图片与附件只导出引用；请分别另存附件。此文件为明文。"
      : "Markdown loses colors, alignment and merged cells. Attachments are references only; save them separately. This file is plaintext."
    panel.begin { [weak self] response in
      guard let self, response == .OK, let url = panel.url, !isClosing, store?.unlocked == true
      else { return }
      do { try Data(markdown.utf8).write(to: url, options: .atomic) } catch {
        store?.error = chinese ? "导出失败，原件已保留。" : "Export failed. Original preserved."
      }
    }
  }
}

@MainActor
final class NoteResourceHandler: NSObject, WKURLSchemeHandler {
  weak var session: NoteEditorSession?
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    let key = ObjectIdentifier(urlSchemeTask)
    guard let session, !session.isClosing, session.store?.unlocked == true,
      let url = urlSchemeTask.request.url,
      url.host?.lowercased() == session.id.uuidString.lowercased(),
      let core = session.store?.core
    else {
      urlSchemeTask.didFailWithError(NoteEditorError.unavailable)
      return
    }
    let id = String(url.path.dropFirst())
    tasks[key] = Task { [weak self, weak session] in
      do {
        let bytes = try await core.readAttachment(noteID: session?.itemID ?? "", id: id)
        guard let self, let session, !Task.isCancelled, tasks[key] != nil, !session.isClosing,
          session.store?.unlocked == true
        else { return }
        guard NSImage(data: bytes) != nil else { throw NoteEditorError.invalidResponse }
        let response = URLResponse(
          url: url,
          mimeType: (bytes.starts(with: [0xFF, 0xD8])
            ? "image/jpeg"
            : bytes.starts(with: [0x47, 0x49, 0x46])
              ? "image/gif"
              : bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) ? "image/webp" : "image/png"),
          expectedContentLength: bytes.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(bytes)
        urlSchemeTask.didFinish()
        tasks.removeValue(forKey: key)
      } catch {
        guard let self, !Task.isCancelled, tasks.removeValue(forKey: key) != nil else { return }
        urlSchemeTask.didFailWithError(NoteEditorError.unavailable)
      }
    }
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
  }
  func cancelAll() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }
}
