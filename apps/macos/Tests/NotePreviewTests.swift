import AppKit
import SwiftUI
import XCTest
@testable import PasswordVault

@MainActor
final class NotePreviewTests: XCTestCase {
  private func editor(_ source: String) -> (NoteTextView, EditableNotePreview.Coordinator, () -> String) {
    var saved = source
    let parent = EditableNotePreview(text: Binding(get: { saved }, set: { saved = $0 }), markdown: true, chinese: true)
    let coordinator = EditableNotePreview.Coordinator(parent)
    let view = NoteTextView(); view.isRichText = false; view.allowsUndo = false
    view.delegate = coordinator; coordinator.configure(view)
    return (view, coordinator, { saved })
  }
  func testProjectionHidesSyntaxAndKeepsSource() {
    let source = "# d\n\n**粗体** 与 *斜体* [链接](https://example.test)\n- 条目\n- [x] 完成\n> 引用\n```swift\nlet x = 1\n```"
    let projection = NoteMarkdownProjection(source)
    XCTAssertEqual(projection.source, source)
    XCTAssertEqual(projection.text, "d\n\n粗体 与 斜体 链接\n• 条目\n☑ 完成\n▎ 引用\n\nlet x = 1\n")
    XCTAssertEqual(projection.starts.count, (projection.text as NSString).length)
    XCTAssertEqual(projection.ends.count, projection.starts.count)
  }
  func testHeadingTypedInPlaceAndUndoRestoresMarkdown() {
    let (view, coordinator, saved) = editor("")
    view.history.beginUndoGrouping()
    for text in ["#", " ", "d"] { view.insertText(text, replacementRange: view.selectedRange()) }
    view.history.endUndoGrouping()
    XCTAssertEqual(saved(), "# d"); XCTAssertEqual(view.string, "d")
    XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
    coordinator.configure(view)
    XCTAssertTrue(view.validateMenuItem(NSMenuItem(title: "Undo", action: #selector(NoteTextView.undo(_:)), keyEquivalent: "z")))
    view.undo(nil); XCTAssertEqual(saved(), ""); XCTAssertEqual(view.string, "")
    view.redo(nil); XCTAssertEqual(saved(), "# d"); XCTAssertEqual(view.string, "d")
  }
  func testHeadingBackspaceRemovesFormattingAndCanUndo() {
    let (view, coordinator, saved) = editor("# 标题")
    defer { withExtendedLifetime(coordinator) {} }
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.history.beginUndoGrouping(); view.deleteBackward(nil); view.history.endUndoGrouping()
    XCTAssertEqual(saved(), "标题"); XCTAssertEqual(view.string, "标题")
    view.undo(nil); XCTAssertEqual(saved(), "# 标题")
  }
  func testCrossParagraphReplacementPreservesUnselectedFormattingAndUndo() {
    let source = "# 标题 👨‍👩‍👧‍👦\n\n第一段\n\n**第二段**\n最后一段"
    let (view, coordinator, saved) = editor(source)
    let range = (view.string as NSString).range(of: "第一段\n\n第二段")
    view.setSelectedRange(range)
    view.history.beginUndoGrouping(); view.insertText("跨段修改 👋", replacementRange: range); view.history.endUndoGrouping()
    XCTAssertEqual(saved(), "# 标题 👨‍👩‍👧‍👦\n\n跨段修改 👋\n最后一段")
    coordinator.configure(view); view.undo(nil)
    XCTAssertEqual(saved(), source); XCTAssertEqual(view.string, NoteMarkdownProjection(source).text)
    view.redo(nil); XCTAssertTrue(saved().contains("跨段修改 👋"))
  }
  func testPartialBoldAndLinkEditsDoNotLoseDelimitersOrURL() {
    let (view, coordinator, saved) = editor("**abcd** [site](https://example.test)")
    defer { withExtendedLifetime(coordinator) {} }
    view.insertText("X", replacementRange: NSRange(location: 1, length: 1))
    XCTAssertEqual(saved(), "**aXcd** [site](https://example.test)")
    view.insertText("页面", replacementRange: (view.string as NSString).range(of: "ite"))
    XCTAssertEqual(saved(), "**aXcd** [s页面](https://example.test)")
    XCTAssertEqual(view.string, "aXcd s页面")
  }
  func testMarkedTextCommitsInsideHiddenHeadingWithoutSyntaxLeak() {
    let (view, coordinator, saved) = editor("# ")
    defer { withExtendedLifetime(coordinator) {} }
    view.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(view.hasMarkedText()); XCTAssertEqual(saved(), "# zhongwen")
    view.insertText("中文", replacementRange: view.markedRange())
    XCTAssertFalse(view.hasMarkedText()); XCTAssertEqual(saved(), "# 中文"); XCTAssertEqual(view.string, "中文")
  }
  func testEscapedSymbolsAndPlainNotesRemainLiteral() {
    XCTAssertEqual(NoteMarkdownProjection("\\*literal\\*").text, "*literal*")
    XCTAssertEqual(NoteMarkdownProjection("# literal", markdown: false).text, "# literal")
    let p = NoteMarkdownProjection("\\*literal\\*")
    XCTAssertEqual(p.replacing(NSRange(location: 0, length: 1), with: "").projection.source, "literal\\*")
  }
  func testDeletingAllRenderedContentLeavesNoHiddenSource() {
    for source in ["**foo *bar* baz**", "```\ncode\n```\nafter", "# Heading"] {
      let (view, coordinator, saved) = editor(source)
      defer { withExtendedLifetime(coordinator) {} }
      let all = NSRange(location: 0, length: (view.string as NSString).length)
      view.history.beginUndoGrouping(); view.insertText("", replacementRange: all); view.history.endUndoGrouping()
      XCTAssertEqual(saved(), "")
      view.insertText("new text", replacementRange: view.selectedRange())
      XCTAssertEqual(saved(), "new text"); XCTAssertEqual(view.string, "new text")
    }
  }
  func testNestedFormattingReplacementAndParagraphJoin() {
    let projection = NoteMarkdownProjection("before **foo *bar* baz** after")
    let selected = (projection.text as NSString).range(of: "foo bar baz")
    XCTAssertEqual(projection.replacing(selected, with: "replacement").projection.source, "before replacement after")
    let paragraphs = NoteMarkdownProjection("before\n# title\nafter")
    XCTAssertEqual(paragraphs.replacing(NSRange(location: 6, length: 1), with: "").projection.source, "beforetitle\nafter")
  }

  func testWholeCodeDocumentReplacementAndTypingAfterClosingFence() {
    for replacement in ["new content", ""] {
      let (view, coordinator, saved) = editor("```\ncode\n```\nafter")
      defer { withExtendedLifetime(coordinator) {} }
      view.history.beginUndoGrouping()
      view.insertText(replacement, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
      view.history.endUndoGrouping()
      XCTAssertEqual(saved(), replacement); XCTAssertEqual(view.string, replacement)
      view.undo(nil); XCTAssertEqual(saved(), "```\ncode\n```\nafter")
      view.redo(nil); XCTAssertEqual(saved(), replacement)
    }
    let (view, coordinator, saved) = editor("```\ncode\n```")
    defer { withExtendedLifetime(coordinator) {} }
    view.history.beginUndoGrouping()
    view.insertText("after", replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
    view.history.endUndoGrouping()
    XCTAssertEqual(saved(), "```\ncode\n```\nafter")
    XCTAssertTrue(view.string.hasSuffix("after"))
    view.undo(nil); XCTAssertEqual(saved(), "```\ncode\n```")
    view.redo(nil); XCTAssertTrue(view.string.hasSuffix("after"))
  }

  func testMarkedTextReplacingWholeCodeDocumentPreservesNewCompositionOnly() {
    let (view, coordinator, saved) = editor("```\ncode\n```\nafter")
    defer { withExtendedLifetime(coordinator) {} }
    view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
    view.history.beginUndoGrouping()
    view.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: view.selectedRange())
    XCTAssertEqual(saved(), "zhongwen")
    view.insertText("中文", replacementRange: view.markedRange())
    view.history.endUndoGrouping()
    XCTAssertEqual(saved(), "中文"); XCTAssertEqual(view.string, "中文")
    view.undo(nil); XCTAssertEqual(saved(), "```\ncode\n```\nafter")
    view.redo(nil); XCTAssertEqual(saved(), "中文"); XCTAssertEqual(view.string, "中文")
  }

}
