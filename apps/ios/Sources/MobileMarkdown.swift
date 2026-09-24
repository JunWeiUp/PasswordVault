import SwiftUI

/// Native block layout; inline links are explicit taps and never load remote images.
struct MobileMarkdown: View {
  let source: String
  private struct Block: Identifiable {
    let id: Int
    let kind: String
    let text: String
    let level: Int
  }
  private var blocks: [Block] {
    var result: [Block] = []
    var code: [String]? = nil
    func add(_ kind: String, _ text: String, _ level: Int = 0) {
      result.append(Block(id: result.count, kind: kind, text: text, level: level))
    }
    for line in source.components(separatedBy: .newlines) {
      if line.hasPrefix("```") {
        if let lines = code {
          add("code", lines.joined(separator: "\n"))
          code = nil
        } else {
          code = []
        }
      } else if code != nil {
        code?.append(line)
      } else if line.hasPrefix("#") {
        let level = line.prefix(while: { $0 == "#" }).count
        if level <= 6 && line.dropFirst(level).hasPrefix(" ") {
          add("heading", String(line.dropFirst(level + 1)), level)
        } else {
          add("text", line)
        }
      } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
        add("bullet", String(line.dropFirst(2)))
      } else if line.hasPrefix("> ") {
        add("quote", String(line.dropFirst(2)))
      } else {
        add("text", line)
      }
    }
    if let code { add("code", code.joined(separator: "\n")) }
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ForEach(blocks) { block in
        switch block.kind {
        case "heading":
          inline(block.text).font(
            block.level == 1 ? .title2.bold() : block.level == 2 ? .title3.bold() : .headline
          ).padding(.top, 8)
        case "bullet":
          HStack(alignment: .top, spacing: 9) {
            Text("•")
            inline(block.text)
          }
        case "quote":
          HStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.3)).frame(width: 3)
            inline(block.text).foregroundStyle(.secondary)
          }.fixedSize(horizontal: false, vertical: true)
        case "code":
          Text(block.text).font(.body.monospaced()).padding(12).frame(
            maxWidth: .infinity, alignment: .leading
          ).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        default: if block.text.isEmpty { Spacer().frame(height: 5) } else { inline(block.text) }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      .environment(
        \.openURL,
        OpenURLAction { url in
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
            ? .systemAction : .discarded
        })
  }
  private func inline(_ text: String) -> Text {
    Text(
      (try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text))
  }
}
