import AppKit
import SwiftUI
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
        Label(store.t("编辑器未能加载。原文已保留，可从更多菜单打开 Markdown 源码。", "The editor could not load. Original text is preserved; use Markdown source in More."), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange).font(.callout)
      }
      MarkdownEditorSurface(item: item, editing: editing, beginEditing: beginEditing, height: $height, failed: $failed)
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
    NoteEditorSession(itemID: item.id, source: item.note, store: store)
  }
  func makeNSView(context: Context) -> NoteWebView {
    let session = context.coordinator
    session.heightChanged = { height = $0 }
    session.failed = { failed = true }
    session.beginEditing = beginEditing
    session.update(source: item.note, editable: store.canEdit(item), editing: editing, chinese: store.chinese)
    session.load()
    return session.webView
  }
  func updateNSView(_ view: NoteWebView, context: Context) {
    context.coordinator.beginEditing = beginEditing
    context.coordinator.update(source: item.note, editable: store.canEdit(item), editing: editing, chinese: store.chinese)
  }
  static func dismantleNSView(_ view: NoteWebView, coordinator: NoteEditorSession) {
    coordinator.heightChanged = nil; coordinator.failed = nil; coordinator.beginEditing = nil
    coordinator.store?.retireNoteEditor(coordinator)
  }
}

@MainActor
final class NoteEditorSession: NSObject, NoteEditorLease, WKScriptMessageHandler, WKNavigationDelegate {
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
  private var ready = false, registered = false, configuring = false
  private var closeTask: Task<Result<String, Error>, Never>?
  private var linkURL: URL?
  let webView: NoteWebView

  init(itemID: String, source: String, store: AppStore) {
    self.itemID = itemID; self.source = source; self.store = store
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.suppressesIncrementalRendering = true
    webView = NoteWebView(frame: .zero, configuration: config)
    super.init()
    config.userContentController.add(WeakNoteMessageHandler(self), name: "noteEditor")
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    webView.setValue(false, forKey: "drawsBackground")
    webView.setAccessibilityIdentifier("note.markdown.editor")
    webView.noteSession = self
  }
  func load() {
    guard let url = Bundle.main.url(forResource: "NoteEditor", withExtension: "html"),
      let html = try? String(contentsOf: url, encoding: .utf8) else { failed?(); return }
    // Only static editor code is loaded here. Note text is passed as an argument
    // after initialization; it is never interpolated into HTML or written to disk.
    webView.loadHTMLString(html, baseURL: nil)
  }
  func update(source incoming: String, editable: Bool, editing: Bool, chinese: Bool) {
    guard !isClosing else { return }
    let changed = source != incoming || self.editable != editable || self.editing != editing || self.chinese != chinese
    self.editable = editable; self.editing = editing; self.chinese = chinese
    if !registered { source = incoming }
    if ready && registered && changed { configure(incoming) }
  }
  private func configure(_ incoming: String) {
    guard !isClosing, ready, registered else { return }
    let expected = revision
    let options: [String: Any] = ["token": id.uuidString, "source": incoming, "expectedRevision": expected,
      "editable": editable, "editing": editing, "chinese": chinese]
    configuring = true
    Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await evaluate("return window.pvEditor.configure(options)", arguments: ["options": options]) as? [String: Any]
        if response?["accepted"] as? Bool == true, revision == expected, !isClosing { source = incoming }
      } catch { if !isClosing { failed?() } }
      configuring = false
    }
  }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, !isClosing,
      let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
    if kind == "ready" {
      guard !ready else { return }; ready = true
      Task { [weak self] in
        guard let self, let store, let latest = await store.prepareNoteEditor(self), !isClosing else { return }
        registered = true; source = latest
        configure(latest)
      }
      return
    }
    if kind == "failure" { failed?(); return }
    guard registered, body["token"] as? String == id.uuidString else { return }
    switch kind {
    case "change":
      guard editable, let text = body["source"] as? String, let number = body["revision"] as? Int, number >= revision else { return }
      revision = number
      if store?.receiveNoteEditorChange(self, text: text) == true { source = text }
    case "editing":
      guard editable else { return }; editing = true; beginEditing?()
    case "height":
      if let value = body["height"] as? Double, value.isFinite { heightChanged?(CGFloat(min(1_000_000, max(360, value)))) }
    case "caret":
      guard editing, editable, let x = body["x"] as? Double,
        let y = body["y"] as? Double, let height = body["height"] as? Double,
        x.isFinite, y.isFinite, height.isFinite else { return }
      let top = webView.isFlipped ? y - 12 : webView.bounds.height - y - height - 12
      let responder = webView.window?.firstResponder as? NSView
      let hadFocus = responder.map { $0 === webView || $0.isDescendant(of: webView) } ?? false
      let didScroll = webView.scrollToVisible(NSRect(x: max(0, x - 8), y: max(0, top), width: 24, height: min(200, height + 24)))
      if didScroll && hadFocus {
        if let responder { webView.window?.makeFirstResponder(responder) }
        Task { [weak self] in
          guard let self, !isClosing, editing, webView.window?.isKeyWindow == true,
            let current = webView.window?.firstResponder as? NSView,
            current === webView || current.isDescendant(of: webView) else { return }
          _ = try? await evaluate("window.pvEditor.refocus()")
        }
      }
    case "state":
      webView.canUndoNote = editable && body["undo"] as? Bool == true
      webView.canRedoNote = editable && body["redo"] as? Bool == true
    case "link":
      guard let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
        let x = body["x"] as? Double, let y = body["y"] as? Double else { return }
      linkURL = url
      let menu = NSMenu()
      let open = NSMenuItem(title: chinese ? "打开链接" : "Open link", action: #selector(openLink), keyEquivalent: "")
      open.target = self; menu.addItem(open)
      menu.popUp(positioning: nil, at: NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y), in: webView)
    default: break
    }
  }
  @objc private func openLink() { if !isClosing, let linkURL { NSWorkspace.shared.open(linkURL) } }
  func command(_ action: String) {
    guard editable, !isClosing, registered else { return }
    Task { _ = try? await evaluate("window.pvEditor.command(action)", arguments: ["action": action]) }
  }
  func capture(closing: Bool) -> Task<Result<String, Error>, Never> {
    if let closeTask { return closeTask }
    if closing { isClosing = true; webView.isHidden = true }
    let task = Task<Result<String, Error>, Never> { [self] in
      defer { if closing { clear() } }
      guard ready && registered else { return .success(source) }
      do {
        guard let result = try await evaluate("return await window.pvEditor.snapshot(close)", arguments: ["close": closing]) as? [String: Any],
          let text = result["source"] as? String else { throw NoteEditorError.invalidResponse }
        return .success(text)
      } catch { return .failure(error) }
    }
    if closing { closeTask = task }
    return task
  }
  private func clear() {
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "noteEditor")
    webView.navigationDelegate = nil; webView.noteSession = nil
    webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
    // Keep the acknowledged source and completed close task until the lease is
    // released. Retirement and locking can consume the same snapshot concurrently.
    linkURL = nil; ready = false; registered = false
  }
  func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any {
    try await withCheckedThrowingContinuation { continuation in
      var finished = false
      webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
        guard !finished else { return }; finished = true; continuation.resume(with: result)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        guard !finished else { return }; finished = true; continuation.resume(throwing: NoteEditorError.timeout)
      }
    }
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed?() }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed?() }
}

@MainActor
private final class WeakNoteMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: NoteEditorSession?
  init(_ target: NoteEditorSession) { self.target = target }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
