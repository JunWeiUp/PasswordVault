import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import PasswordVault

@MainActor
final class RichNoteTests: XCTestCase {
  private let password = "Synthetic rich note window fixture"
  private func wait(_ session: NoteEditorSession, _ expression: String) async throws {
    for _ in 0..<150 {
      if (try? await session.evaluate("return Boolean(\(expression))")) as? Bool == true { return }
      try await Task.sleep(nanoseconds: 30_000_000)
    }
    XCTFail("Editor did not reach expected state: \(expression)")
    throw NoteEditorError.timeout
  }
  func testRichPayloadPreservesOriginalAndMetadata() throws {
    var item = VaultItem.blank(type: "secureNote", title: "Fixture")
    item.note = "**original**"
    item.editorSource =
      "{\"format\":\"rich-v1\",\"document\":{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"edited\"}]}]},\"text\":\"edited\"}"
    XCTAssertEqual(item.note, "edited")
    XCTAssertTrue(item.isRichNote)
    XCTAssertEqual(item.fields["noteOriginal"]?.object["source"]?.string, "**original**")
    let source = item.editorSource
    item.editorSource = source
    XCTAssertEqual(item.editorSource, source)
    XCTAssertEqual(item.fields["noteOriginal"]?.object["source"]?.string, "**original**")
  }
  func testFormattingTableFindAndReadonlyInRealWebKit() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = AppStore(directory: folder)
    defer { try? FileManager.default.removeItem(at: folder) }
    await store.authenticate(password: password, create: true)
    var note = VaultItem.blank(type: "secureNote", title: "Formatting fixture")
    note.note = "**first** first"
    try await store.saveRecord(note)
    let session = NoteEditorSession(itemID: note.id, source: note.note, store: store)
    session.update(source: note.note, editable: true, editing: true, chinese: true)
    session.webView.frame = NSRect(x: 0, y: 0, width: 750, height: 700)
    session.load()
    try await wait(
      session,
      "window.pvEditor && document.querySelector('.ProseMirror')?.textContent === 'first first'")
    _ = try await session.evaluate(
      "document.querySelector('[data-action=find]').click();const input=document.querySelector('.findbar input');input.value='first first';input.dispatchEvent(new Event('input'))"
    )
    try await wait(
      session,
      "window.pvEditor.diagnostics().selection.to - window.pvEditor.diagnostics().selection.from === 11"
    )
    _ = try await session.evaluate("document.querySelector('[data-action=closeFind]').click()")
    _ = try await session.evaluate(
      """
      const root=document.querySelector('.ProseMirror'); root.focus();
      const r=document.createRange();r.selectNodeContents(root.querySelector('p'));
      const s=window.getSelection();s.removeAllRanges();s.addRange(r);
      """)
    try await Task.sleep(nanoseconds: 50_000_000)
    _ = try await session.evaluate("document.querySelector('[data-action=toggleBold]').click()")
    try await wait(
      session, "document.querySelector('.ProseMirror strong')?.textContent === 'first first'")
    _ = try await session.evaluate(
      "document.querySelector('[data-action=find]').click(); const f=document.querySelector('.findbar input');f.value='first';f.dispatchEvent(new Event('input'));document.querySelectorAll('.findbar input')[1].value='second'; document.querySelector('[data-action=replaceAll]').click()"
    )
    try await wait(
      session, "document.querySelector('.ProseMirror').textContent === 'second second'")
    _ = try await session.evaluate(
      "document.querySelector('[data-action=closeFind]').click();document.querySelector('[data-action=insertTable]').click()"
    )
    try await wait(session, "document.querySelectorAll('.ProseMirror table tr').length === 3")
    _ = try await session.evaluate("document.querySelector('[data-action=addRowAfter]').click()")
    try await wait(session, "document.querySelectorAll('.ProseMirror table tr').length === 4")
    _ = try await session.evaluate(
      """
      const root=document.querySelector('.ProseMirror');root.focus();
      const paragraph=[...root.querySelectorAll('p')].find(p=>p.textContent.includes('second'));
      const range=document.createRange();range.selectNodeContents(paragraph);
      const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
      """)
    try await Task.sleep(nanoseconds: 50_000_000)
    _ = try await session.evaluate("document.querySelector('[data-action=setColorPicker]').click()")
    let anchored =
      try await session.evaluate(
        """
        const trigger=document.querySelector('[data-action=setColorPicker]').getBoundingClientRect();
        const panel=document.querySelector('#palette-setColor').getBoundingClientRect();
        return Math.abs(panel.top - trigger.bottom - 6) < 2 && panel.left >= 0 && panel.right <= innerWidth;
        """) as? Bool
    XCTAssertEqual(anchored, true)
    _ = try await session.evaluate(
      "document.querySelector('[data-action=\"setColor#c62828\"]').click()")
    try await wait(session, "document.querySelector('#palette-setColor').hidden")
    try await wait(
      session,
      "document.querySelector('.ProseMirror span[style]')?.style.color === 'rgb(198, 40, 40)'")
    _ = try await session.evaluate(
      """
      document.querySelector('[data-action=setHighlightPicker]').click();
      const input=document.querySelector('#palette-setHighlight input');input.value='#abcdef';
      document.querySelector('[data-action=setHighlightApply]').click();
      """)
    try await wait(session, "document.querySelector('#palette-setHighlight').hidden")
    try await wait(
      session,
      "document.querySelector('.ProseMirror mark')?.getAttribute('data-color') === '#abcdef'")
    let before = session.source
    session.update(source: before, editable: true, editing: false, chinese: true)
    try await wait(session, "!window.pvEditor.diagnostics().editable")
    let stale =
      try await session.evaluate(
        "return window.pvEditor.configure(options).accepted",
        arguments: [
          "options": [
            "token": session.id.uuidString, "source": before, "sequence": -1,
            "expectedRevision": -1, "editable": true, "editing": true, "chinese": true,
          ]
        ]) as? Bool
    XCTAssertEqual(stale, false)
    try await wait(session, "!window.pvEditor.diagnostics().editable")
    store.lock()
    await store.finishLock()
    await store.authenticate(password: password, create: false)
    XCTAssertTrue(store.items.first?.isRichNote == true)
    XCTAssertTrue(store.items.first?.editorSource.contains("table") == true)
    store.lock()
    await store.finishLock()
  }
  func testPastedImageUsesEncryptedNativeResourceAndSurvivesReopen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder)
    await store.authenticate(password: password, create: true)
    let note = VaultItem.blank(type: "secureNote", title: "Synthetic attachment")
    try await store.saveRecord(note)
    let session = NoteEditorSession(itemID: note.id, source: note.note, store: store)
    session.update(source: note.note, editable: true, editing: true, chinese: true)
    session.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
    session.load()
    try await wait(session, "window.pvEditor && window.pvEditor.diagnostics().editable")
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32
    )!
    let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    _ = try await session.evaluate(
      """
      const data=Uint8Array.from(atob(png),c=>c.charCodeAt(0));const dt=new DataTransfer();
      dt.items.add(new File([data],'Synthetic.png',{type:'image/png'}));
      const root=document.querySelector('.ProseMirror');root.focus();
      root.dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}));
      """, arguments: ["png": image.base64EncodedString()])
    try await wait(session, "document.querySelector('.ProseMirror img')?.naturalWidth === 4")
    await store.flushChanges()
    let saved = try XCTUnwrap(store.items.first)
    XCTAssertTrue(saved.isRichNote)
    let document = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(saved.fields["noteDocument"]))
    XCTAssertTrue(String(describing: document).contains("vaultImage"))
    XCTAssertFalse(saved.editorSource.contains(image.base64EncodedString()))
    let backup = try await store.perform(["op": .string("export"), "password": .string(password)])
    XCTAssertFalse(backup.object["content"]!.string.contains("Synthetic.png"))
    store.lock()
    await store.finishLock()
    let rejected =
      try? await session.evaluate("return document.querySelector('.ProseMirror img') !== null")
      as? Bool
    XCTAssertNotEqual(rejected, true)
    await store.authenticate(password: password, create: false)
    let restored = try XCTUnwrap(store.items.first)
    let reopened = NoteEditorSession(
      itemID: restored.id, source: restored.editorSource, store: store)
    reopened.update(source: restored.editorSource, editable: true, editing: true, chinese: true)
    reopened.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
    reopened.load()
    try await wait(reopened, "document.querySelector('.ProseMirror img')?.naturalWidth === 4")
    store.lock()
    await store.finishLock()
  }
  func testWheelScrollsWholePageWithoutChangingSelectionOrFocus() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(directory: folder)
    await store.authenticate(password: password, create: true)
    var note = VaultItem.blank(type: "secureNote", title: "Wheel fixture")
    note.note = (0..<100).map { "Paragraph \($0)" }.joined(separator: "\n\n")
    try await store.saveRecord(note)
    let session = NoteEditorSession(itemID: note.id, source: note.note, store: store)
    session.update(source: note.note, editable: true, editing: true, chinese: true)
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 750, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 750, height: 600))
    scroll.hasVerticalScroller = true
    let web = session.webView
    web.frame = NSRect(x: 0, y: 0, width: 730, height: 6000)
    scroll.documentView = web
    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    session.load()
    try await wait(session, "window.pvEditor && window.pvEditor.diagnostics().editable")
    window.makeFirstResponder(web)
    _ = try await session.evaluate("window.pvEditor.refocus()")
    try await Task.sleep(nanoseconds: 200_000_000)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
    scroll.reflectScrolledClipView(scroll.contentView)
    let responder = window.firstResponder
    let selection =
      try await session.evaluate("return JSON.stringify(window.pvEditor.diagnostics().selection)")
      as? String
    func wheel(_ delta: Double, mode: Int = 0, target: String = ".ProseMirror", x: Double = 0)
      async throws -> Bool
    {
      let cancelled =
        try await session.evaluate(
          """
          const event = new WheelEvent('wheel', {deltaY: dy, deltaX: dx, deltaMode: mode, bubbles: true, cancelable: true});
          document.querySelector(target).dispatchEvent(event);return event.defaultPrevented;
          """, arguments: ["dy": delta, "dx": x, "mode": mode, "target": target]) as? Bool
      try await Task.sleep(nanoseconds: 100_000_000)
      return cancelled == true
    }
    let start = scroll.contentView.bounds.origin.y
    let down = try await wheel(120)
    XCTAssertTrue(down)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, start + 120, accuracy: 1)
    let up = try await wheel(-2, mode: 1)
    XCTAssertTrue(up)
    XCTAssertLessThan(scroll.contentView.bounds.origin.y, start + 120)
    let beforeHorizontal = scroll.contentView.bounds.origin.y
    let horizontal = try await wheel(0, x: 80)
    XCTAssertFalse(horizontal)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, beforeHorizontal, accuracy: 1)
    _ = try await session.evaluate(
      """
      const menu=document.createElement('div'); menu.id='scroll-test-menu';
      menu.style.cssText='height:40px;overflow-y:auto'; menu.innerHTML='<div style="height:400px">menu</div>';
      document.body.append(menu);
      """)
    let menuScroll = try await wheel(40, target: "#scroll-test-menu")
    XCTAssertFalse(menuScroll)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, beforeHorizontal, accuracy: 1)
    // Pixel deltas also represent the stream emitted during trackpad momentum.
    for _ in 0..<10 { _ = try await wheel(3.5) }
    XCTAssertEqual(scroll.contentView.bounds.origin.y, beforeHorizontal + 35, accuracy: 1)
    let afterSelection =
      try await session.evaluate("return JSON.stringify(window.pvEditor.diagnostics().selection)")
      as? String
    XCTAssertEqual(afterSelection, selection)
    XCTAssertTrue(window.firstResponder === responder)
    session.update(source: session.source, editable: true, editing: false, chinese: true)
    try await wait(session, "!window.pvEditor.diagnostics().editable")
    let beforePreview = scroll.contentView.bounds.origin.y
    _ = try await wheel(80)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, beforePreview + 80, accuracy: 1)
    _ = try await wheel(100000)
    XCTAssertLessThanOrEqual(scroll.contentView.bounds.maxY, web.bounds.maxY + 1)
    _ = try await wheel(-100000)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
    store.lock()
    await store.finishLock()
  }

  func testNativeWindowContinuousReturnForParagraphListAndLongNote() async throws {
    for original in [
      "start", "- first", (0..<100).map { "Paragraph \($0)" }.joined(separator: "\n\n"),
    ] {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let store = AppStore(directory: folder)
      await store.authenticate(password: password, create: true)
      var note = VaultItem.blank(type: "secureNote", title: "Synthetic keyboard fixture")
      note.note = original
      try await store.saveRecord(note)
      store.selectedID = note.id
      store.notePreviewModes[note.id] = false
      let host = NSHostingView(rootView: WorkspaceView().environmentObject(store))
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1200, height: 780),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 780))
      host.frame = container.bounds
      host.autoresizingMask = [.width, .height]
      container.addSubview(host)
      window.contentView = container
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      func find(_ v: NSView) -> NoteWebView? {
        if let web = v as? NoteWebView { return web }
        for child in v.subviews { if let web = find(child) { return web } }
        return nil
      }
      var web: NoteWebView?
      for _ in 0..<100 {
        web = find(host)
        if web != nil { break }
        try await Task.sleep(nanoseconds: 30_000_000)
      }
      let surface = try XCTUnwrap(web)
      let session = try XCTUnwrap(surface.noteSession)
      try await wait(
        session, "window.pvEditor && document.querySelector('.ProseMirror')?.textContent.length > 0"
      )
      window.makeFirstResponder(surface)
      _ = try await session.evaluate(
        "const root=document.querySelector('.ProseMirror');root.focus();const r=document.createRange();r.selectNodeContents(root);r.collapse(false);const s=window.getSelection();s.removeAllRanges();s.addRange(r);"
      )
      try await wait(session, "window.pvEditor.diagnostics().focused")
      for iteration in 0..<100 {
        for (text, key): (String, UInt16) in [("x", 7), ("\r", 36)] {
          let event = try XCTUnwrap(
            NSEvent.keyEvent(
              with: .keyDown, location: .zero, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
              context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
              keyCode: key))
          window.sendEvent(event)
          try await Task.sleep(nanoseconds: 15_000_000)
        }
        let focused =
          try await session.evaluate("return window.pvEditor.diagnostics().focused") as? Bool
        XCTAssertEqual(focused, true, "Lost focus after Return \(iteration)")
      }
      // WebKit reports the caret before SwiftUI applies the new content height.
      // Wait for that asynchronous layout/scroll rather than sampling mid-frame.
      var caretVisible = false
      for _ in 0..<100 {
        let caretResult = try await session.evaluate("return window.pvEditor.diagnostics().caret")
        let caret = try XCTUnwrap(caretResult as? [String: Double])
        let y = caret["top"] ?? 0
        let point = surface.convert(
          NSPoint(x: 10, y: surface.isFlipped ? y : surface.bounds.height - y), to: nil)
        caretVisible = window.contentView!.bounds.insetBy(dx: -1, dy: -1).contains(point)
        if caretVisible { break }
        try await Task.sleep(nanoseconds: 30_000_000)
      }
      XCTAssertTrue(caretVisible, "Caret must remain in the visible window after scrolling")
      let count =
        try await session.evaluate(
          "return (document.querySelector('.ProseMirror').textContent.match(/x/g)||[]).length")
        as? Int
      XCTAssertEqual(count, 100)
      let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 25))
      container.addSubview(titleField)
      XCTAssertTrue(window.makeFirstResponder(titleField))
      let nativeResponder = window.firstResponder
      try await Task.sleep(nanoseconds: 100_000_000)
      XCTAssertTrue(
        window.firstResponder === nativeResponder,
        "Asynchronous scrolling must not steal native focus")
      store.focusNoteBody(note.id)
      for _ in 0..<100 {
        let current = window.firstResponder as? NSView
        if current === surface || current?.isDescendant(of: surface) == true { break }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      try await wait(session, "window.pvEditor.diagnostics().focused")
      let focusedView = window.firstResponder as? NSView
      XCTAssertTrue(focusedView === surface || focusedView?.isDescendant(of: surface) == true)
      titleField.removeFromSuperview()
      await store.flushChanges()
      store.lock()
      await store.finishLock()
      await store.authenticate(password: password, create: false)
      XCTAssertEqual(store.items.first?.note.filter { $0 == "x" }.count, 100)
      store.lock()
      await store.finishLock()
      window.close()
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
