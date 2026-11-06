/** Tiptap JSON is the canonical document; rendering is a one-way projection.
 * Unknown nodes, attributes and marks never pass through a reduced schema. */
export type Node = { type: string; text?: string; attrs?: Record<string, any>; marks?: Mark[]; content?: Node[]; [key: string]: any };
export type Mark = { type: string; attrs?: Record<string, any>; [key: string]: any };
export type Note = { id: string; note?: string; noteFormat?: string; noteDocument?: Node; noteOriginal?: unknown };
export type Patch = { noteFormat: "rich-v1"; noteDocument: Node; note: string; noteOriginal?: unknown };
export const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v));
export function documentFor(item: Note): Node {
  if (item.noteFormat === "rich-v1") {
    if (item.noteDocument?.type !== "doc" || !Array.isArray(item.noteDocument.content)) throw Error("笔记文档无效，原始内容已保留。");
    return clone(item.noteDocument);
  }
  // Literal import preserves unsupported Markdown/HTML and remote image URLs.
  return { type: "doc", content: (item.note ?? "").split("\n").map(text => ({ type: "paragraph", ...(text ? { content: [{ type: "text", text }] } : {}) })) };
}
export function plainText(n: Node): string {
  if (n.type === "text") return n.text ?? "";
  if (n.type === "hardBreak") return "\n";
  if (n.type === "vaultImage") return n.attrs?.caption || n.attrs?.name || "";
  if (n.type === "vaultAttachment") return n.attrs?.name || "";
  return (n.content ?? []).map(plainText).join(["paragraph", "heading", "codeBlock"].includes(n.type) ? "" : "\n");
}
export function patchFor(item: Note, doc: Node): Patch {
  return { noteFormat: "rich-v1", noteDocument: clone(doc), note: plainText(doc),
    ...(item.noteOriginal !== undefined ? { noteOriginal: clone(item.noteOriginal) } : item.noteFormat !== "rich-v1" ? { noteOriginal: { format: item.noteFormat ?? "", source: item.note ?? "" } } : {}) };
}
export function at(doc: Node, path: number[]): Node { return path.reduce((n, i) => n.content![i], doc); }
export function change(doc: Node, path: number[], fn: (n: Node) => void): Node { const next = clone(doc); fn(at(next, path)); return next; }
export function editableBlocks(doc: Node): { path: number[]; node: Node }[] {
  const out: { path: number[]; node: Node }[] = [];
  function visit(n: Node, path: number[]) {
    if (["paragraph", "heading", "codeBlock"].includes(n.type)) out.push({ path, node: n });
    else if (["doc", "bulletList", "orderedList", "taskList", "listItem", "taskItem", "blockquote", "table", "tableRow", "tableCell", "tableHeader"].includes(n.type)) (n.content ?? []).forEach((c, i) => visit(c, [...path, i]));
    else out.push({ path, node: n });
  }
  visit(doc, []); return out;
}
export const canEdit = (n: Node) => ["paragraph", "heading", "codeBlock"].includes(n.type) && (n.content ?? []).every(c => c.type === "text" || c.type === "hardBreak");
function slice(n: Node, from: number, to: number): Node[] {
  let offset = 0;
  return (n.content ?? []).flatMap(c => {
    const len = plainText(c).length, start = Math.max(0, from - offset), end = Math.min(len, to - offset); offset += len;
    return end <= start ? [] : [{ ...clone(c), ...(c.type === "text" ? { text: c.text!.slice(start, end) } : {}) }];
  });
}
/** A minimal contiguous edit leaves every unaffected span and unknown mark intact. */
export function replaceText(doc: Node, path: number[], value: string): Node {
  const n = at(doc, path); if (!canEdit(n)) return doc;
  const old = plainText(n); if (old === value) return doc;
  let a = 0, b = 0;
  while (a < old.length && a < value.length && old[a] === value[a]) a++;
  while (b < old.length - a && b < value.length - a && old[old.length - 1 - b] === value[value.length - 1 - b]) b++;
  const before = slice(n, 0, a), after = slice(n, old.length - b, old.length);
  const nearby = slice(n, Math.max(0, a - 1), Math.max(1, a))[0];
  const inserted = value.slice(a, value.length - b);
  return change(doc, path, node => { node.content = [...before, ...(inserted ? [{ type: "text", text: inserted, ...(nearby?.marks ? { marks: clone(nearby.marks) } : {}) }] : []), ...after]; });
}
export function markRange(doc: Node, path: number[], start: number, end: number, mark: Mark): Node {
  const n = at(doc, path); if (!canEdit(n) || n.type === "codeBlock" || start === end) return doc;
  const a = Math.max(0, Math.min(start, end)), b = Math.min(plainText(n).length, Math.max(start, end));
  const middle = slice(n, a, b), remove = middle.filter(c => c.type === "text").every(c => c.marks?.some(m => m.type === mark.type));
  return change(doc, path, node => { node.content = [...slice(n, 0, a), ...middle.map(c => c.type !== "text" ? c : { ...c, marks: [...(c.marks ?? []).filter(m => m.type !== mark.type), ...(remove ? [] : [mark])] }), ...slice(n, b, plainText(n).length)]; });
}
export function appendBlock(doc: Node, type: string): Node {
  const p: Node = { type: "paragraph" };
  let n: Node = { type };
  if (type === "heading") n.attrs = { level: 2 };
  if (["bulletList", "orderedList", "taskList"].includes(type)) n.content = [{ type: type === "taskList" ? "taskItem" : "listItem", ...(type === "taskList" ? { attrs: { checked: false } } : {}), content: [p] }];
  if (type === "blockquote") n.content = [p];
  if (type === "table") n.content = [0, 1].map(() => ({ type: "tableRow", content: [0, 1].map(() => ({ type: "tableCell", attrs: { colspan: 1, rowspan: 1, colwidth: null }, content: [clone(p)] })) }));
  const next = clone(doc); next.content!.push(n); return next;
}
