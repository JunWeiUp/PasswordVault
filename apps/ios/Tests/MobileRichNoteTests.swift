import XCTest
import WebKit
@testable import PasswordVault

@MainActor
final class MobileRichNoteTests: XCTestCase {
  func testLocalEditorCaptureAndLockedDraftRetainRichDocument() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MobileVaultStore(directory: directory)
    await store.start(); await store.authenticate("synthetic rich bridge fixture", create: true)
    XCTAssertTrue(store.unlocked)
    var note = VaultItem.blank(type: "secureNote", title: "Synthetic note")
    note.note = "Original"
    let saved = await store.save(note); XCTAssertTrue(saved)
    let session = MobileNoteSession(item: note, store: store)
    session.changed = { store.pendingDraft = $0 }
    session.load()
    var ready = false
    for _ in 0..<200 {
      if let result = try? await session.evaluate("return !!document.querySelector('[contenteditable=true]')"), result as? Bool == true { ready = true; break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(ready, "The bundled editor must initialize without a network connection")
    guard ready else { session.discard(); await store.close(); return }
    _ = try await session.evaluate("const el=document.querySelector('[contenteditable=true]');el.focus();const range=document.createRange();range.selectNodeContents(el);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);document.execCommand('bold');document.execCommand('insertText',false,'RICH_IOS_CANARY')")
    try await Task.sleep(nanoseconds: 150_000_000)
    _ = try await session.evaluate("window.webkit.messageHandlers.noteEditor.postMessage({kind:'change',token:'wrong-token',source:'ATTACK',revision:99})")
    let captured = await session.capture(closing: false).value
    XCTAssertEqual(captured?.note, "RICH_IOS_CANARY")
    XCTAssertEqual(captured?.string("noteFormat"), "rich-v1")
    if let captured { let saved = await store.save(captured); XCTAssertTrue(saved) }
    store.captureRichDraft = { session.capture(closing: true) }
    store.lock()
    await store.authenticate("synthetic rich bridge fixture", create: false)
    XCTAssertEqual(store.recoveredDraft?.note, "RICH_IOS_CANARY")
    XCTAssertEqual(store.recoveredDraft?.fields["noteDocument"]?.object["type"]?.string, "doc")
    store.discardDraft(); await store.close()
    try FileManager.default.removeItem(at: directory)
  }

  func testAttachmentReadIsBoundToOwningNote() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let core = try MobileCore(directory: directory)
    _ = try await core.call(["op":.string("create"),"password":.string("synthetic attachment fixture")])
    let first = VaultItem.blank(type: "secureNote", title: "First")
    let second = VaultItem.blank(type: "secureNote", title: "Second")
    for item in [first, second] { _ = try await core.call(["op":.string("save"),"item":try .from(item)]) }
    let meta = try await core.importAttachment(noteID: first.id, name: "fixture.txt", mime: "text/plain", data: Data("synthetic attachment".utf8))
    let id = meta.object["id"]!.string
    let bytes = try await core.readAttachment(noteID: first.id, id: id)
    XCTAssertEqual(bytes, Data("synthetic attachment".utf8))
    do { _ = try await core.readAttachment(noteID: second.id, id: id); XCTFail("Cross-note attachment read accepted") } catch {}
    await core.close(); try FileManager.default.removeItem(at: directory)
  }
}
