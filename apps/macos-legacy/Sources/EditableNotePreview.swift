import AppKit
import SwiftUI

/// The native text view edits a rendered projection, never zero-width or invisible
/// Markdown characters. Source, selection and undo are coordinated explicitly.
struct EditableNotePreview: NSViewRepresentable {
  @Binding var text: String
  let markdown: Bool
  let chinese: Bool
  var editing = true
  var canEdit = true
  var beginEditing: () -> Void = {}
  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NoteTextView {
    let view = NoteTextView(frame: .zero)
    view.isRichText = false; view.importsGraphics = false
    view.isEditable = canEdit && editing; view.isSelectable = true
    view.allowsUndo = false // Undo stores Markdown source, not presentation text.
    view.drawsBackground = false
    view.textContainerInset = NSSize(width: 0, height: 4)
    view.textContainer?.lineFragmentPadding = 0
    view.isHorizontallyResizable = false; view.isVerticallyResizable = true
    view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
    view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
    view.isContinuousSpellCheckingEnabled = false; view.isAutomaticLinkDetectionEnabled = false
    view.isAutomaticDataDetectionEnabled = false
    view.setAccessibilityIdentifier("note.preview.body")
    view.delegate = context.coordinator
    context.coordinator.configure(view)
    return view
  }
  func updateNSView(_ view: NoteTextView, context: Context) {
    context.coordinator.parent = self
    let coordinator = context.coordinator
    view.beginDirectEditing = canEdit ? { [weak view] in view?.isEditable = true; beginEditing() } : nil
    view.isEditable = canEdit && editing
    view.setAccessibilityLabel(chinese ? "笔记正文" : "Note body"); view.chinese = chinese
    if coordinator.projection.source != text && !view.hasMarkedText() {
      coordinator.projection = NoteMarkdownProjection(text, markdown: markdown)
      view.history.removeAllActions(); coordinator.render(view, sourceSelection: nil)
    } else if coordinator.lastMarkdown != markdown { coordinator.configure(view) }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoteTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0, let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    return CGSize(width: width, height: max(360, ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)) + 32))
  }
  static func dismantleNSView(_ view: NoteTextView, coordinator: Coordinator) {
    view.delegate = nil; view.beginDirectEditing = nil; view.backspaceAtBlockStart = nil; view.compositionDidEnd = nil
    view.history.removeAllActions(); view.string = ""
    coordinator.projection = NoteMarkdownProjection(""); coordinator.pendingChange = nil; coordinator.compositionStart = nil
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    struct Snapshot { let source: String; let selection: NSRange }
    struct Change { let range: NSRange; let replacement: String; let before: Snapshot }
    var parent: EditableNotePreview
    var projection: NoteMarkdownProjection
    var lastMarkdown: Bool?
    var pendingChange: Change?
    var compositionStart: Snapshot?
    private var rendering = false
    private weak var textView: NoteTextView?
    init(_ parent: EditableNotePreview) { self.parent = parent; projection = NoteMarkdownProjection(parent.text, markdown: parent.markdown) }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
      guard !rendering, let replacementString else { return true }
      pendingChange = Change(range: affectedCharRange, replacement: replacementString,
        before: Snapshot(source: projection.source, selection: projection.sourceRange(for: textView.selectedRange())))
      return true
    }
    func textDidChange(_ notification: Notification) {
      guard !rendering, let view = notification.object as? NoteTextView, view.string != projection.text else { return }
      let change: Change
      if let pending = pendingChange,
        NSMaxRange(pending.range) <= (projection.text as NSString).length,
        (projection.text as NSString).replacingCharacters(in: pending.range, with: pending.replacement) == view.string { change = pending }
      else {
        // AX replacement, spell services and other native edits still map through
        // a minimal source edit instead of serializing away existing formatting.
        let old = Array(projection.text.utf16), new = Array(view.string.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count) && old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix && old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let range = NSRange(location: prefix, length: old.count - prefix - suffix)
        let replacement = (view.string as NSString).substring(with: NSRange(location: prefix, length: new.count - prefix - suffix))
        change = Change(range: range, replacement: replacement, before: Snapshot(source: projection.source, selection: projection.sourceRange(for: range)))
      }
      pendingChange = nil
      let edit = projection.replacing(change.range, with: change.replacement, preservingComposition: compositionStart != nil)
      projection = edit.projection
      parent.text = projection.source
      if view.hasMarkedText() {
        if compositionStart == nil { compositionStart = change.before }
      } else {
        let before = compositionStart ?? change.before; compositionStart = nil
        if before.source != projection.source { registerUndo(before, view: view) }
        projection = NoteMarkdownProjection(projection.source, markdown: parent.markdown)
        render(view, sourceSelection: NSRange(location: edit.caret, length: 0))
      }
      view.invalidateIntrinsicContentSize()
    }
    func textDidEndEditing(_ notification: Notification) {
      guard let view = notification.object as? NoteTextView else { return }
      parent.text = projection.source
      if !view.hasMarkedText() { configure(view) }
    }
    func configure(_ view: NoteTextView) {
      textView = view
      view.compositionDidEnd = { [weak self, weak view] in if let self, let view { self.finishComposition(view) } }
      guard !view.hasMarkedText() else { return }
      let selection = projection.sourceRange(for: view.selectedRange())
      projection = NoteMarkdownProjection(projection.source, markdown: parent.markdown)
      view.backspaceAtBlockStart = { [weak self, weak view] in
        guard let self, let view, view.selectedRange().length == 0, !view.hasMarkedText(),
          let block = self.projection.blocks.first(where: { $0.contentStart == view.selectedRange().location }) else { return false }
        let before = Snapshot(source: self.projection.source, selection: self.projection.sourceRange(for: view.selectedRange()))
        let source = (self.projection.source as NSString).replacingCharacters(in: block.sourcePrefix, with: "")
        self.registerUndo(before, view: view)
        self.projection = NoteMarkdownProjection(source, markdown: self.parent.markdown); self.parent.text = source
        self.render(view, sourceSelection: NSRange(location: block.sourcePrefix.location, length: 0)); return true
      }
      render(view, sourceSelection: selection)
    }
    func render(_ view: NoteTextView, sourceSelection: NSRange?) {
      guard !view.hasMarkedText() else { return }
      rendering = true
      view.textStorage?.setAttributedString(projection.attributed)
      if let selection = sourceSelection {
        let start = projection.displayOffset(for: selection.location), end = projection.displayOffset(for: NSMaxRange(selection))
        view.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
      }
      view.typingAttributes = NoteMarkdownProjection.baseAttributes
      view.insertionPointColor = .labelColor
      lastMarkdown = parent.markdown; rendering = false
      view.invalidateIntrinsicContentSize()
    }
    func finishComposition(_ view: NoteTextView) {
      guard !view.hasMarkedText(), let before = compositionStart else { return }
      compositionStart = nil
      if before.source != projection.source { registerUndo(before, view: view) }
      let selection = projection.sourceRange(for: view.selectedRange())
      projection = NoteMarkdownProjection(projection.source, markdown: parent.markdown)
      render(view, sourceSelection: selection)
    }
    private func registerUndo(_ snapshot: Snapshot, view: NoteTextView) {
      view.history.registerUndo(withTarget: self) { target in target.restore(snapshot) }
      view.history.setActionName(parent.chinese ? "编辑笔记" : "Edit note")
    }
    private func restore(_ snapshot: Snapshot) {
      guard let view = textView else { return }
      let current = Snapshot(source: projection.source, selection: projection.sourceRange(for: view.selectedRange()))
      registerUndo(current, view: view)
      projection = NoteMarkdownProjection(snapshot.source, markdown: parent.markdown)
      parent.text = snapshot.source; compositionStart = nil; pendingChange = nil
      render(view, sourceSelection: snapshot.selection)
    }
  }
}

final class NoteTextView: NSTextView {
  var chinese = true
  let history = UndoManager()
  // AppKit must not mix its rendered-text deltas with our source snapshots.
  override var undoManager: UndoManager? { nil }
  var compositionDidEnd: (() -> Void)?
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    didChangeText()
  }
  override func unmarkText() {
    super.unmarkText()
    DispatchQueue.main.async { [weak self] in self?.compositionDidEnd?() }
  }
  var beginDirectEditing: (() -> Void)?
  var backspaceAtBlockStart: (() -> Bool)?
  override func mouseDown(with event: NSEvent) {
    if !isEditable { beginDirectEditing?() }
    super.mouseDown(with: event)
  }
  override func deleteBackward(_ sender: Any?) {
    if isEditable && backspaceAtBlockStart?() == true { return }
    super.deleteBackward(sender)
  }
  override var acceptsFirstResponder: Bool { true }
  @objc func undo(_ sender: Any?) { history.undo() }
  @objc func redo(_ sender: Any?) { history.redo() }
  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(undo(_:)) { return history.canUndo }
    if menuItem.action == #selector(redo(_:)) { return history.canRedo }
    return super.validateMenuItem(menuItem)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event)
    let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
    let source = string as NSString
    guard index <= source.length,
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return menu }
    if index < source.length, let url = textStorage?.attribute(NoteMarkdownProjection.linkKey, at: index, effectiveRange: nil) as? URL,
      ["https", "http", "mailto"].contains(url.scheme ?? "") {
      let item = NSMenuItem(title: chinese ? "打开链接" : "Open link", action: #selector(openNoteLink(_:)), keyEquivalent: "")
      item.target = self; item.representedObject = url; menu?.addItem(.separator()); menu?.addItem(item)
    }
    let paragraph = source.paragraphRange(for: NSRange(location: index, length: 0))
    for match in detector.matches(in: string, range: paragraph) {
      guard let url = match.url, ["https", "http", "mailto"].contains(url.scheme ?? "") else { continue }
      let item = NSMenuItem(title: chinese ? "打开链接" : "Open link", action: #selector(openNoteLink(_:)), keyEquivalent: "")
      item.target = self; item.representedObject = url
      menu?.addItem(.separator()); menu?.addItem(item)
    }
    return menu
  }
  @objc private func openNoteLink(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSWorkspace.shared.open(url)
  }
  // Keep one outer scroll surface. Clicking anywhere in the body's remaining space
  // places the caret in this same document, including an empty note.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
