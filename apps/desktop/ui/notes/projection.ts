import type { TextViewDocument, TextViewBlock, TextViewInline } from "nsh/base";
import { plainText, type Node } from "./model";
function inline(n: Node): TextViewInline {
  if (n.type === "hardBreak") return { type: "break" };
  let out: TextViewInline = { type: "text", text: n.text ?? plainText(n) };
  for (const m of n.marks ?? []) {
    const type = ({ bold: "strong", italic: "emphasis", strike: "strikethrough", underline: "underline" } as const)[m.type as "bold"];
    if (type) out = { type, content: [out] };
    else if (m.type === "highlight") out = { type: "highlight", color: m.attrs?.color, content: [out] };
    else if (m.type === "code") out = { type: "code", code: n.text ?? "" };
    else if (m.type === "link" && /^(https?:\/\/|mailto:)/i.test(m.attrs?.href ?? "")) out = { type: "link", url: m.attrs!.href, content: [out] };
  }
  return out;
}
function block(n: Node): TextViewBlock {
  const content = (n.content ?? []).map(inline);
  switch (n.type) {
    case "paragraph": return { type: "paragraph", content };
    case "heading": return { type: "heading", level: Math.min(6, Math.max(1, n.attrs?.level ?? 1)) as 1, content };
    case "codeBlock": return { type: "codeBlock", code: plainText(n), language: n.attrs?.language ?? undefined };
    case "horizontalRule": return { type: "rule" };
    case "blockquote": return { type: "blockquote", children: (n.content ?? []).map(block) };
    case "bulletList": case "orderedList": case "taskList": return { type: "list", ordered: n.type === "orderedList", start: n.attrs?.start, items: (n.content ?? []).map(i => ({ ...(i.type === "taskItem" ? { checked: !!i.attrs?.checked } : {}), children: (i.content ?? []).map(block) })) };
    // A text projection avoids unsupported table spans and all remote resources.
    default: return { type: "paragraph", content: [{ type: "text", text: plainText(n) || `[${n.type}]` }] };
  }
}
export function project(doc: Node): TextViewDocument { return { blocks: (doc.content ?? []).map(block) }; }
