import type { TextViewDocument, TextViewBlock, TextViewInline } from "nsh/base";
import { plainText, type Node } from "./model";

const WIKILINK_RE = /\[\[([^\]\n]+)\]\]/g;

function splitWikilinks(text: string): TextViewInline[] {
  if (!text.includes("[[")) return [{ type: "text", text }];
  const parts: TextViewInline[] = [];
  let cursor = 0;
  WIKILINK_RE.lastIndex = 0;
  for (let m = WIKILINK_RE.exec(text); m; m = WIKILINK_RE.exec(text)) {
    if (m.index > cursor) {
      parts.push({ type: "text", text: text.slice(cursor, m.index) });
    }
    const target = m[1].trim();
    if (target) {
      parts.push({
        type: "link",
        url: `pv-wiki://${encodeURIComponent(target)}`,
        content: [{ type: "text", text: target }],
      });
    } else {
      parts.push({ type: "text", text: m[0] });
    }
    cursor = m.index + m[0].length;
  }
  if (cursor < text.length) parts.push({ type: "text", text: text.slice(cursor) });
  return parts.length ? parts : [{ type: "text", text }];
}

function wrapMarks(base: TextViewInline, marks: Node["marks"], rawText: string): TextViewInline {
  let out = base;
  for (const m of marks ?? []) {
    const type = ({ bold: "strong", italic: "emphasis", strike: "strikethrough", underline: "underline" } as const)[m.type as "bold"];
    if (type) out = { type, content: [out] };
    else if (m.type === "highlight") out = { type: "highlight", color: m.attrs?.color, content: [out] };
    else if (m.type === "code") out = { type: "code", code: rawText };
    else if (m.type === "link" && /^(https?:\/\/|mailto:|pv-asset:\/\/|pv-wiki:\/\/)/i.test(m.attrs?.href ?? "")) {
      out = { type: "link", url: m.attrs!.href, content: [out] };
    }
  }
  return out;
}

function inlineNodes(nodes: Node[] | undefined): TextViewInline[] {
  const out: TextViewInline[] = [];
  for (const n of nodes ?? []) {
    if (n.type === "hardBreak") {
      out.push({ type: "break" });
      continue;
    }
    if (n.type === "vaultAttachment" || n.type === "vaultImage") {
      const id = String(n.attrs?.attachmentId ?? "");
      const name = String(n.attrs?.name ?? "附件");
      out.push({
        type: "link",
        url: id ? `pv-asset://${id}` : "",
        content: [{ type: "text", text: `📎 ${name}` }],
      });
      continue;
    }
    const rawText = n.text ?? plainText(n);
    const hasLinkOrCode = (n.marks ?? []).some((m) => m.type === "code" || m.type === "link");
    if (n.type === "text" && !hasLinkOrCode && rawText.includes("[[")) {
      for (const seg of splitWikilinks(rawText)) {
        out.push(wrapMarks(seg, n.marks, rawText));
      }
      continue;
    }
    out.push(wrapMarks({ type: "text", text: rawText }, n.marks, rawText));
  }
  return out;
}

function cellInlines(cell: Node): TextViewInline[] {
  const out: TextViewInline[] = [];
  const children = cell.content ?? [];
  children.forEach((child, idx) => {
    if (idx > 0) out.push({ type: "break" });
    out.push(...inlineNodes(child.content ?? [child]));
  });
  return out;
}

function projectTable(n: Node): TextViewBlock {
  const tableRows = (n.content ?? []).filter((r) => r.type === "tableRow");
  if (!tableRows.length) return { type: "paragraph", content: [] };
  const toCells = (row: Node) =>
    (row.content ?? []).map((cell) => ({
      content: cellInlines(cell),
      ...(Number(cell.attrs?.colspan) > 1 ? { colspan: Number(cell.attrs?.colspan) } : {}),
    }));
  const firstIsHeader = (tableRows[0].content ?? []).some((c) => c.type === "tableHeader");
  const head = firstIsHeader ? toCells(tableRows[0]) : [];
  const bodyRows = (firstIsHeader ? tableRows.slice(1) : tableRows).map(toCells);
  return { type: "table", head, rows: bodyRows };
}

function block(n: Node): TextViewBlock {
  const content = inlineNodes(n.content);
  switch (n.type) {
    case "paragraph":
      return { type: "paragraph", content };
    case "heading":
      return { type: "heading", level: Math.min(6, Math.max(1, n.attrs?.level ?? 1)) as 1, content };
    case "codeBlock":
      return { type: "codeBlock", code: plainText(n), language: n.attrs?.language ?? undefined };
    case "horizontalRule":
      return { type: "rule" };
    case "blockquote":
      return { type: "blockquote", children: (n.content ?? []).map(block) };
    case "bulletList":
    case "orderedList":
    case "taskList":
      return {
        type: "list",
        ordered: n.type === "orderedList",
        start: n.attrs?.start,
        items: (n.content ?? []).map((i) => ({
          ...(i.type === "taskItem" ? { checked: !!i.attrs?.checked } : {}),
          children: (i.content ?? []).map(block),
        })),
      };
    case "table":
      return projectTable(n);
    case "vaultAttachment":
    case "vaultImage": {
      const id = String(n.attrs?.attachmentId ?? "");
      const name = String(n.attrs?.name ?? "加密附件");
      return {
        type: "paragraph",
        content: [
          {
            type: "link",
            url: id ? `pv-asset://${id}` : "",
            content: [{ type: "text", text: `📎 ${name}` }],
          },
        ],
      };
    }
    default:
      return { type: "paragraph", content: [{ type: "text", text: plainText(n) || `[${n.type}]` }] };
  }
}

export function project(doc: Node): TextViewDocument {
  return { blocks: (doc.content ?? []).map(block) };
}
