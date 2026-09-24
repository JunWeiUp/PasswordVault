import AppKit
import WebKit
import XCTest
@testable import PasswordVault

@MainActor
final class MilkdownEditorTests: XCTestCase {
  private let pass = "Synthetic editor lifecycle fixture"
  private func fixture(_ source: String) async throws -> (AppStore, VaultItem, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = AppStore(directory: folder)
    await store.authenticate(password: pass, create: true)
    var note = VaultItem.blank(type: "secureNote", title: "Synthetic Milkdown")
    note.note = source; note.set("noteFormat", "markdown")
    try await store.saveRecord(note)
    return (store, note, folder)
  }
  private func wait(_ session: NoteEditorSession, until expression: String) async throws {
    for _ in 0..<100 {
      if (try? await session.evaluate("return Boolean(\(expression))")) as? Bool == true { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Editor did not reach expected state: \(expression)")
    throw NoteEditorError.timeout
  }
  func testRealWebKitKeepsOriginalOnOpenAndCommitsFinalInputBeforeLock() async throws {
    let original = "# Fixture\n\n- first\n- second\n"
    let (store, note, folder) = try await fixture(original)
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = NoteEditorSession(itemID: note.id, source: original, store: store)
    session.update(source: original, editable: true, editing: true, chinese: true)
    session.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
    session.load()
    try await wait(session, until: "window.pvEditor && document.querySelector('.ProseMirror')?.textContent.includes('first')")
    XCTAssertFalse(session.webView.configuration.websiteDataStore.isPersistent)
    XCTAssertEqual(store.items.first?.note, original, "Opening must not normalize the stored original")
    _ = try await session.evaluate("""
      const p=document.querySelector('.ProseMirror li p');
      p.focus();const r=document.createRange();r.selectNodeContents(p);r.collapse(false);
      const s=window.getSelection();s.removeAllRanges();s.addRange(r);
      document.execCommand('insertText',false,' final');
      """)
    store.lock()
    XCTAssertFalse(store.unlocked)
    await store.finishLock()
    await store.authenticate(password: pass, create: false)
    XCTAssertTrue(store.items.first?.note.contains("first final") == true)
    XCTAssertTrue(store.items.first?.note.contains("second") == true)
    store.lock(); await store.finishLock()
  }
  func testRealWebKitClosedSnapshotCanBeConsumedAgainByLock() async throws {
    let (store, note, folder) = try await fixture("before")
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = NoteEditorSession(itemID: note.id, source: note.note, store: store)
    session.update(source: note.note, editable: true, editing: true, chinese: true)
    session.load()
    try await wait(session, until: "document.querySelector('.ProseMirror')?.textContent === 'before'")
    // Intercept the final snapshot to model input that has not reached Swift.
    _ = try await session.evaluate("window.pvEditor.snapshot = async () => ({source:'last input',revision:1})")
    let first = try await session.capture(closing: true).value.get()
    let repeated = try await session.capture(closing: true).value.get()
    XCTAssertEqual(first, "last input"); XCTAssertEqual(repeated, first)
    XCTAssertEqual(session.source, "before", "Keep the handover baseline until the store consumes it")
    store.lock(); await store.finishLock(); await store.authenticate(password: pass, create: false)
    XCTAssertEqual(store.items.first?.note, "last input")
    store.lock(); await store.finishLock()
  }
  func testSourceModeWaitsForFinalInputBeforeAcceptingSourceEdits() async throws {
    let (store, note, folder) = try await fixture("before")
    defer { try? FileManager.default.removeItem(at: folder) }
    let editor = SyntheticEditor(itemID: note.id, source: "before", result: "before final")
    _ = await store.prepareNoteEditor(editor)
    let opened = await store.prepareNoteSource(note.id)
    XCTAssertTrue(opened)
    var source = try XCTUnwrap(store.items.first)
    XCTAssertEqual(source.note, "before final")
    source.note += " source edit"; store.editNote(source)
    store.lock(); await store.finishLock(); await store.authenticate(password: pass, create: false)
    XCTAssertEqual(store.items.first?.note, "before final source edit")
    store.lock(); await store.finishLock()
  }
  func testSourceModeFailureCannotOpenStaleWritableSnapshot() async throws {
    let (store, note, folder) = try await fixture("preserve")
    defer { try? FileManager.default.removeItem(at: folder) }
    let editor = SyntheticEditor(itemID: note.id, source: "preserve", result: "unconfirmed")
    editor.fail = true; _ = await store.prepareNoteEditor(editor)
    let opened = await store.prepareNoteSource(note.id)
    XCTAssertFalse(opened); XCTAssertEqual(store.items.first?.note, "preserve")
    store.lock(); await store.finishLock()
  }
  func testRealWebKitListsCaretHistoryAndUntrustedHTML() async throws {
    let original = "- first\n- second\n\n<script>window.pvInjected=true</script>\n\n![remote](https://example.invalid/private-image.png)"
    let (store, note, folder) = try await fixture(original)
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = NoteEditorSession(itemID: note.id, source: original, store: store)
    session.update(source: original, editable: true, editing: true, chinese: true)
    session.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
    session.load()
    try await wait(session, until: "document.querySelector('.ProseMirror li p')?.textContent === 'first'")
    let safe = try await session.evaluate("return !window.pvInjected && !document.querySelector('.ProseMirror script')") as? Bool
    XCTAssertEqual(safe, true)
    let blocked = try await session.evaluate("return fetch('https://example.invalid/no-network').then(()=>false,()=>true)") as? Bool
    XCTAssertEqual(blocked, true)
    _ = try await session.evaluate("""
      const root=document.querySelector('.ProseMirror'),p=root.querySelector('li p');root.focus();
      const r=document.createRange();r.setStart(p.firstChild,2);r.collapse(true);
      const s=window.getSelection();s.removeAllRanges();s.addRange(r);
      document.execCommand('insertText',false,'X');
      """)
    try await wait(session, until: "document.querySelector('.ProseMirror li p').textContent === 'fiXrst'")
    // Native echo must not replace the document or move the caret.
    session.update(source: session.source, editable: true, editing: true, chinese: false)
    _ = try await session.evaluate("document.execCommand('insertText',false,'Y')")
    try await wait(session, until: "document.querySelector('.ProseMirror li p').textContent === 'fiXYrst'")
    _ = try await session.evaluate("window.pvEditor.command('undo')")
    try await wait(session, until: "document.querySelector('.ProseMirror li p').textContent === 'first'")
    _ = try await session.evaluate("window.pvEditor.command('redo')")
    try await wait(session, until: "document.querySelector('.ProseMirror li p').textContent === 'fiXYrst'")
    _ = try await session.evaluate("""
      const root=document.querySelector('.ProseMirror'),p=root.querySelector('li p');
      const r=document.createRange();r.selectNodeContents(p);r.collapse(false);
      const s=window.getSelection();s.removeAllRanges();s.addRange(r);
      """)
    _ = try await session.evaluate("document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}))")
    try await wait(session, until: "document.querySelectorAll('.ProseMirror li').length === 3")
    _ = try await session.evaluate("document.execCommand('insertText',false,'continued')")
    try await wait(session, until: "document.querySelectorAll('.ProseMirror li')[1].textContent === 'continued'")
    store.lock(); await store.finishLock(); await store.authenticate(password: pass, create: false)
    let saved = try XCTUnwrap(store.items.first?.note)
    XCTAssertTrue(saved.contains("continued")); XCTAssertTrue(saved.contains("<script>"))
    store.lock(); await store.finishLock()
  }
  func testSimulatedCompositionRejectsStaleReplacementAndPreservesChinese() async throws {
    let (store, note, folder) = try await fixture("start end")
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = NoteEditorSession(itemID: note.id, source: note.note, store: store)
    session.update(source: note.note, editable: true, editing: true, chinese: true)
    session.load()
    try await wait(session, until: "document.querySelector('.ProseMirror')?.textContent === 'start end'")
    _ = try await session.evaluate("""
      const root=document.querySelector('.ProseMirror'); root.focus();
      const r=document.createRange();r.setStart(root.querySelector('p').firstChild,6);r.collapse(true);
      const s=window.getSelection();s.removeAllRanges();s.addRange(r);
      root.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true,data:''}));
      document.execCommand('insertText',false,'测试');
      """)
    let accepted = try await session.evaluate("return window.pvEditor.configure(options).accepted", arguments: ["options": ["token":session.id.uuidString,"source":"stale text","expectedRevision":-1,"editable":true,"editing":true,"chinese":true]]) as? Bool
    XCTAssertEqual(accepted, false)
    _ = try await session.evaluate("document.querySelector('.ProseMirror').dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:'测试'}))")
    _ = try await session.evaluate("document.execCommand('insertText',false,'X')")
    try await wait(session, until: "document.querySelector('.ProseMirror').textContent === 'start 测试Xend'")
    store.lock(); await store.finishLock(); await store.authenticate(password: pass, create: false)
    XCTAssertTrue(store.items.first?.note.contains("start 测试Xend") == true)
    store.lock(); await store.finishLock()
  }
  func testSnapshotReceivesQueuedLastInputAndRejectsLateOldMessages() async throws {
    let (store, note, folder) = try await fixture("before")
    defer { try? FileManager.default.removeItem(at: folder) }
    let editor = SyntheticEditor(itemID: note.id, source: "before", result: "last input")
    _ = await store.prepareNoteEditor(editor)
    store.lock()
    XCTAssertFalse(store.receiveNoteEditorChange(editor, text: "late attacker text"))
    await store.finishLock(); await store.authenticate(password: pass, create: false)
    XCTAssertEqual(store.items.first?.note, "last input")
    XCTAssertFalse(store.receiveNoteEditorChange(editor, text: "old epoch"))
    store.lock(); await store.finishLock()
  }
  func testRapidReopenWaitsForRetiringEditorAndReadonlyCannotWrite() async throws {
    let (store, note, folder) = try await fixture("before")
    defer { try? FileManager.default.removeItem(at: folder) }
    let old = SyntheticEditor(itemID: note.id, source: "before", result: "retired final")
    _ = await store.prepareNoteEditor(old); store.retireNoteEditor(old)
    let next = SyntheticEditor(itemID: note.id, source: "before", result: "next")
    let initialized = await store.prepareNoteEditor(next)
    XCTAssertEqual(initialized, "retired final")
    XCTAssertFalse(store.receiveNoteEditorChange(old, text: "stale"))
    await store.trash(try XCTUnwrap(store.items.first))
    XCTAssertFalse(store.receiveNoteEditorChange(next, text: "write into trash"))
    store.lock(); await store.finishLock()
  }
  func testFailedCaptureBlocksExportAndPreservesExistingData() async throws {
    let (store, note, folder) = try await fixture("keep original")
    defer { try? FileManager.default.removeItem(at: folder) }
    let editor = SyntheticEditor(itemID: note.id, source: "keep original", result: "not confirmed")
    editor.fail = true; _ = await store.prepareNoteEditor(editor)
    do { try await store.prepareSnapshot(); XCTFail("Unconfirmed editor must block export") } catch {}
    XCTAssertTrue(store.saveFailed); XCTAssertEqual(store.items.first?.note, "keep original")
    store.lock(); await store.finishLock()
  }
  func testMetadataSaveDoesNotOverwriteInputStillInsideEditor() async throws {
    let (store, note, folder) = try await fixture("before")
    defer { try? FileManager.default.removeItem(at: folder) }
    let editor = SyntheticEditor(itemID: note.id, source: "before", result: "last text")
    _ = await store.prepareNoteEditor(editor)
    var favorite = note; favorite.fields["isFavorite"] = .bool(true)
    try await store.saveRecord(favorite)
    XCTAssertEqual(store.items.first?.note, "last text"); XCTAssertTrue(store.items.first?.isFavorite == true)
    store.lock(); await store.finishLock()
  }
}

@MainActor
private final class SyntheticEditor: NoteEditorLease {
  let id = UUID(), itemID: String
  let source: String, result: String
  var isClosing = false, fail = false
  private var closing: Task<Result<String, Error>, Never>?
  init(itemID: String, source: String, result: String) { self.itemID = itemID; self.source = source; self.result = result }
  func capture(closing shouldClose: Bool) -> Task<Result<String, Error>, Never> {
    if let closing { return closing }
    isClosing = shouldClose
    let task = Task<Result<String, Error>, Never> {
      try? await Task.sleep(nanoseconds: 30_000_000)
      return fail ? .failure(NoteEditorError.unavailable) : .success(result)
    }
    if shouldClose { closing = task }
    return task
  }
}
