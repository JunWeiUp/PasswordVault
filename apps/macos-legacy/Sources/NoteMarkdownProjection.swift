import AppKit

/// Rendered UTF-16 characters carry source ranges. Markdown stays in encrypted
/// storage; hidden delimiters never become invisible editable characters.
struct NoteMarkdownProjection {
  struct Block { var sourcePrefix: NSRange; var displayStart: Int; var contentStart: Int }
  struct Wrapper { var source: NSRange; var display: NSRange }
  var source: String
  var attributed: NSMutableAttributedString
  var starts: [Int] = []
  var ends: [Int] = []
  var blocks: [Block] = []
  var wrappers: [Wrapper] = []
  private var closedFenceAtEnd = false
  var text: String { attributed.string }

  init(_ source: String, markdown: Bool = true) {
    self.source = source
    attributed = NSMutableAttributedString(string: "")
    let raw = source as NSString
    guard markdown else { append(source, sourceRange: NSRange(location: 0, length: raw.length)); return }
    var offset = 0, fenced = false
    for line in source.components(separatedBy: "\n") {
      let value = line as NSString
      let full = NSRange(location: offset, length: value.length)
      var attributes = Self.baseAttributes
      var prefix = 0
      let displayStart = attributed.length
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
        closedFenceAtEnd = fenced && NSMaxRange(full) == raw.length
        fenced.toggle()
        blocks.append(Block(sourcePrefix: full, displayStart: displayStart, contentStart: displayStart))
      } else if fenced {
        attributes[.font] = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        append(line, sourceRange: full, attributes: attributes)
      } else if line.trimmingCharacters(in: .whitespaces).range(of: "^(?:-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
        append("────────", sourceRange: full, attributes: attributes)
      } else {
        if let match = Self.match("^#{1,6}[ \\t]+", in: line) {
          prefix = match.length
          let level = min(3, line.prefix(while: { $0 == "#" }).count)
          attributes[.font] = NSFont.systemFont(ofSize: [24.0, 20.0, 17.0][level - 1], weight: .semibold)
          let style = NSMutableParagraphStyle(); style.lineSpacing = 7; style.paragraphSpacingBefore = 8; style.paragraphSpacing = 6
          attributes[.paragraphStyle] = style
        } else if let match = Self.match("^\\s*[-*+] \\[[ xX]\\] ", in: line) {
          prefix = match.length
          append(line.lowercased().contains("[x]") ? "☑ " : "☐ ", sourceRange: NSRange(location: offset, length: prefix), attributes: attributes)
        } else if let match = Self.match("^\\s*[-*+] +", in: line) {
          prefix = match.length
          append("• ", sourceRange: NSRange(location: offset, length: prefix), attributes: attributes)
        } else if let match = Self.match("^\\s*>[ \\t]?", in: line) {
          prefix = match.length
          attributes[.foregroundColor] = NSColor.secondaryLabelColor
          append("▎ ", sourceRange: NSRange(location: offset, length: prefix), attributes: attributes)
        }
        if prefix > 0 { blocks.append(Block(sourcePrefix: NSRange(location: offset, length: prefix), displayStart: displayStart, contentStart: attributed.length)) }
        let body = value.substring(from: prefix)
        if let parsed = try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true)) {
          for run in parsed.runs {
            let content = String(parsed[run.range].characters)
            guard let position = run.markdownSourcePosition, let swiftRange = Range(position, in: body) else {
              append(content, sourceRange: NSRange(location: offset + prefix, length: (body as NSString).length), attributes: attributes); continue
            }
            let local = NSRange(swiftRange, in: body)
            let sourceRange = NSRange(location: offset + prefix + local.location, length: local.length)
            var style = attributes
            var font = style[.font] as! NSFont
            if let intent = run.inlinePresentationIntent {
              if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
              if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
              if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) }
              if intent.contains(.strikethrough) { style[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            style[.font] = font
            if let link = run.link { style[.foregroundColor] = NSColor.linkColor; style[Self.linkKey] = link }
            let displayed = NSRange(location: attributed.length, length: (content as NSString).length)
            append(content, sourceRange: sourceRange, attributes: style)
            for marker in ["***", "___", "**", "__", "~~", "*", "_", "`"] {
              let n = (marker as NSString).length
              if sourceRange.location >= n && NSMaxRange(sourceRange) + n <= raw.length,
                raw.substring(with: NSRange(location: sourceRange.location - n, length: n)) == marker,
                raw.substring(with: NSRange(location: NSMaxRange(sourceRange), length: n)) == marker {
                wrappers.append(Wrapper(source: NSRange(location: sourceRange.location - n, length: sourceRange.length + 2 * n), display: displayed)); break
              }
            }
            if sourceRange.location > 0, raw.substring(with: NSRange(location: sourceRange.location - 1, length: 1)) == "[",
              let suffix = Self.match("^\\]\\([^\\n]*?\\)", in: raw.substring(from: NSMaxRange(sourceRange))) {
              wrappers.append(Wrapper(source: NSRange(location: sourceRange.location - 1, length: sourceRange.length + 1 + suffix.length), display: displayed))
            }
          }
        } else { append(body, sourceRange: NSRange(location: offset + prefix, length: value.length - prefix), attributes: attributes) }
      }
      offset += value.length
      if offset < raw.length { append("\n", sourceRange: NSRange(location: offset, length: 1), attributes: attributes); offset += 1 }
    }
  }

  static let linkKey = NSAttributedString.Key("PasswordVault.previewLink")
  static var baseAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 7; paragraph.paragraphSpacing = 5
    return [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
  }
  private static func match(_ pattern: String, in text: String) -> NSRange? {
    (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range
  }
  private mutating func append(_ value: String, sourceRange: NSRange, attributes: [NSAttributedString.Key: Any] = Self.baseAttributes) {
    attributed.append(NSAttributedString(string: value, attributes: attributes))
    let original = (source as NSString).substring(with: sourceRange)
    let units = Array(value.utf16), raw = Array(original.utf16)
    if units == raw {
      for i in units.indices { starts.append(sourceRange.location + i); ends.append(sourceRange.location + i + 1) }
    } else if value == "• " || value == "☐ " || value == "☑ " || value == "▎ " || value == "────────" {
      for i in units.indices {
        starts.append(sourceRange.location + sourceRange.length * i / max(1, units.count))
        ends.append(sourceRange.location + sourceRange.length * (i + 1) / max(1, units.count))
      }
    } else {
      var cursor = 0
      for unit in units {
        let start = cursor
        if cursor < raw.count && raw[cursor] == 92 && cursor + 1 < raw.count && raw[cursor + 1] == unit { cursor += 2 }
        else if cursor < raw.count && raw[cursor] == 38, let end = raw[cursor...].firstIndex(of: 59) { cursor = end + 1 }
        else { while cursor < raw.count && raw[cursor] != unit { cursor += 1 }; cursor = min(raw.count, cursor + 1) }
        starts.append(sourceRange.location + start); ends.append(sourceRange.location + cursor)
      }
    }
  }

  func sourceRange(for displayed: NSRange) -> NSRange {
    let location = min(displayed.location, starts.count), end = min(NSMaxRange(displayed), starts.count)
    if displayed.length == 0 {
      return NSRange(location: location < starts.count ? starts[location] : (source as NSString).length, length: 0)
    }
    guard end > location else { return NSRange(location: (source as NSString).length, length: 0) }
    var a = starts[location], b = ends[end - 1]
    for wrapper in wrappers where displayed.location <= wrapper.display.location && NSMaxRange(displayed) >= NSMaxRange(wrapper.display) {
      a = min(a, wrapper.source.location); b = max(b, NSMaxRange(wrapper.source))
    }
    // Runs split nested emphasis. Expand enclosing delimiters around the whole
    // selection as well as wrappers around individual runs.
    let raw = source as NSString
    var expanded = true
    while expanded {
      expanded = false
      for marker in ["***", "___", "**", "__", "~~", "*", "_", "`"] {
        let n = (marker as NSString).length
        if a >= n, b + n <= raw.length,
           raw.substring(with: NSRange(location: a - n, length: n)) == marker,
           raw.substring(with: NSRange(location: b, length: n)) == marker {
          a -= n; b += n; expanded = true; break
        }
      }
    }
    // Joining paragraphs removes the second paragraph's hidden block prefix.
    for block in blocks where location < block.displayStart && end >= block.displayStart {
      if block.sourcePrefix.location <= b { b = max(b, NSMaxRange(block.sourcePrefix)) }
    }
    return NSRange(location: a, length: b - a)
  }
  func displayOffset(for sourceOffset: Int) -> Int { ends.prefix(while: { $0 <= sourceOffset }).count }

  /// Keep a one-to-one provisional mapping during an input-method composition.
  /// It is rendered only after the composition commits, not on every candidate.
  func replacing(_ range: NSRange, with replacement: String, preservingComposition: Bool = false) -> (projection: Self, caret: Int) {
    let rawRange: NSRange
    if !preservingComposition && range.location == 0 && range.length == starts.count && range.length > 0 {
      // An explicit select-all replacement must leave no hidden fence/delimiter.
      rawRange = NSRange(location: 0, length: (source as NSString).length)
    } else { rawRange = sourceRange(for: range) }
    // A hidden closing fence is not an editable insertion point. Start a new
    // paragraph outside it when typing at the end of the rendered document.
    let replacement = closedFenceAtEnd && range.length == 0 && range.location == starts.count && !replacement.isEmpty && !replacement.hasPrefix("\n") ? "\n" + replacement : replacement
    let nextSource = (source as NSString).replacingCharacters(in: rawRange, with: replacement)
    let nextText = (text as NSString).replacingCharacters(in: range, with: replacement)
    let inserted = (replacement as NSString).length
    let delta = inserted - rawRange.length
    var result = Self(nextSource, markdown: false)
    result.attributed = NSMutableAttributedString(string: nextText, attributes: Self.baseAttributes)
    result.starts = Array(starts.prefix(range.location)) + (0..<inserted).map { rawRange.location + $0 } + starts.dropFirst(NSMaxRange(range)).map { $0 + delta }
    result.ends = Array(ends.prefix(range.location)) + (0..<inserted).map { rawRange.location + $0 + 1 } + ends.dropFirst(NSMaxRange(range)).map { $0 + delta }
    return (result, rawRange.location + inserted)
  }
}
