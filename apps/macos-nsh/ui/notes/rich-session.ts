import { createRichEditor, defineExtension, richExtension, StarterKit, TableKit } from "nsh/base";
import { clone, type Node } from "./model";

const attrs = (names: string[]) => Object.fromEntries(names.map(name => [name, { default: null }]));
const VaultImage = defineExtension({ name: "vaultImage", node: {
  group: "block", atom: true, attrs: attrs(["attachmentId", "name", "mime", "width", "caption", "src", "alt"]), extra: { render: "image" },
} });
const VaultAttachment = defineExtension({ name: "vaultAttachment", node: {
  group: "block", atom: true, attrs: attrs(["attachmentId", "name", "mime", "size"]),
  toDOM: ["span", "Attachment"],
} });
const LegacyAttributes = defineExtension({ name: "vaultLegacyAttributes", addGlobalAttributes: () => [
  { types: ["link"], attributes: attrs(["target", "rel", "class"]) },
] });

/** Runtime image bytes never enter the persisted rich-v1 document. */
export function storedDocument(doc: Node): Node {
  const result = clone(doc);
  function visit(n: Node) {
    if (n.type === "vaultImage" && n.attrs) { delete n.attrs.src; delete n.attrs.alt; }
    for (const child of n.content ?? []) visit(child);
  }
  visit(result); return result;
}
function normalized(value: any): any {
  if (Array.isArray(value)) return value.map(normalized);
  if (!value || typeof value !== "object") return value;
  const out: Record<string, any> = {};
  for (const key of Object.keys(value).sort()) {
    let v = value[key];
    if (key === "attrs") {
      const defaults: Record<string, any> = value.type === "orderedList" ? { start: 1 } : value.type === "taskItem" ? { checked: false } : ["tableCell", "tableHeader"].includes(value.type) ? { colspan: 1, rowspan: 1 } : {};
      v = Object.fromEntries(Object.entries(v ?? {}).filter(([name, x]) => x !== null && !(name in defaults && x === defaults[name])));
    }
    if ((key === "attrs" && !Object.keys(v).length) || ((key === "content" || key === "marks") && !v.length)) continue;
    out[key] = normalized(v);
    if (key === "marks") out[key].sort((a: any, b: any) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  }
  return out;
}
export const equivalent = (a: Node, b: Node) => JSON.stringify(normalized(a)) === JSON.stringify(normalized(b));
export function createNoteSession(doc: Node, viewDoc: Node = doc) {
  if (!equivalent(doc, storedDocument(viewDoc))) throw Error("附件视图与原文不一致");
  // Do not enable network image nodes or automatic external-link opening.
  const editor = createRichEditor({ extensions: [
    StarterKit.configure({ image: false, link: { openOnClick: false }, trailingNode: false }),
    TableKit, VaultImage, VaultAttachment, LegacyAttributes, richExtension("vaultAttachmentViews"),
  ], content: viewDoc, editable: false });
  if (!equivalent(doc, storedDocument(editor.getJSON() as Node))) { editor.dispose(); throw Error("此笔记包含暂不支持的格式，已保留原文并设为只读。"); }
  return editor;
}
