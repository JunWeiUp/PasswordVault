import { expect, open, test } from "nsh/test";
import { appendBlock, clone, documentFor, markRange, patchFor, plainText, replaceText, type Node } from "../ui/notes/model";
import { project } from "../ui/notes/projection";

const rich: Node = { type: "doc", customVersion: 7, content: [
  { type: "paragraph", attrs: { textAlign: "right" }, content: [{ type: "text", text: "bold", marks: [
    { type: "bold" }, { type: "italic" }, { type: "underline" }, { type: "strike" }, { type: "code" },
    { type: "textStyle", attrs: { color: "#ff0000" } }, { type: "highlight", attrs: { color: "#ffffff" } },
    { type: "link", attrs: { href: "https://example.test", target: "_blank" } }, { type: "futureMark", attrs: { custom: true } },
  ] }, { type: "hardBreak" }, { type: "text", text: "tail" }] },
  { type: "heading", attrs: { level: 3, textAlign: "center" }, content: [{ type: "text", text: "Title" }] },
  { type: "bulletList", content: [{ type: "listItem", content: [{ type: "paragraph" }] }] },
  { type: "orderedList", attrs: { start: 4 }, content: [{ type: "listItem", content: [{ type: "paragraph" }] }] },
  { type: "taskList", content: [{ type: "taskItem", attrs: { checked: true }, content: [{ type: "paragraph" }] }] },
  { type: "blockquote", content: [{ type: "paragraph" }] },
  { type: "codeBlock", attrs: { language: "rust" }, content: [{ type: "text", text: "fn main() {}" }] },
  { type: "horizontalRule" },
  { type: "table", content: [{ type: "tableRow", content: [{ type: "tableHeader", attrs: { colspan: 2, rowspan: 2, colwidth: [120, 140] }, content: [{ type: "paragraph" }] }, { type: "tableCell", content: [{ type: "paragraph" }] }] }] },
  { type: "vaultImage", attrs: { attachmentId: "image-id", name: "picture", mime: "image/png", width: 480, caption: "caption" } },
  { type: "vaultAttachment", attrs: { attachmentId: "file-id", name: "file", mime: "application/pdf", size: 42 } },
  { type: "futureNode", attrs: { preserved: [1, 2] }, content: [{ type: "text", text: "future" }] },
] };

test("rich-v1 round-trips all existing nodes, marks, attributes and unknown extensions", () => {
  const item = { id: "fixture", noteFormat: "rich-v1", noteDocument: rich };
  const doc = documentFor(item);
  expect(patchFor(item, doc).noteDocument).toEqual(rich);
  project(doc);
  expect(doc).toEqual(rich);
  const edited = replaceText(doc, [1], "New Title");
  expect(edited.content![0]).toEqual(rich.content![0]);
  expect(edited.content!.slice(2)).toEqual(rich.content!.slice(2));
  expect(patchFor(item, edited).note).toContain("New Title");
});

test("first real edit retains exact legacy source and existing original", () => {
  const item = { id: "legacy", noteFormat: "markdown", note: "# Original\r\n![remote](https://example.test/a.png)\n<html>" };
  const doc = documentFor(item);
  expect(item.noteFormat).toBe("markdown");
  const patch = patchFor(item, replaceText(doc, [0], "changed"));
  expect(patch.noteOriginal).toEqual({ format: "markdown", source: item.note });
  expect(patch.noteFormat).toBe("rich-v1");
  const saved = { ...item, ...patch };
  expect(patchFor(saved, appendBlock(saved.noteDocument, "taskList")).noteOriginal).toEqual(patch.noteOriginal);
});

test("range formatting preserves neighboring spans and unknown marks", () => {
  const doc = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "abc中文def", marks: [{ type: "futureMark" }] }] }] };
  const marked = markRange(doc, [0], 3, 5, { type: "bold" });
  expect(plainText(marked)).toBe("abc中文def");
  expect(marked.content![0].content![1].marks).toEqual([{ type: "futureMark" }, { type: "bold" }]);
  const edited = replaceText(marked, [0], "abc中文Xdef");
  expect(plainText(edited)).toBe("abc中文Xdef");
  expect(doc.content[0].content[0].text).toBe("abc中文def");
  const opaque = clone(rich); opaque.content![0].content!.push({ type: "futureInline" });
  expect(replaceText(opaque, [0], "overwrite")).toEqual(opaque);
});

test("official RichEditor edits and keeps legacy original", async () => {
  const app = await open("../ui/notes/TestHarness.tsx", { width: 900, height: 900, platform: "macos" });
  await app.waitFor("id:note-rich-editor");
  expect(app.texts()).toContain("saves:0");
  await app.type("id:note-rich-editor", "中文追加");
  await app.wait(200);
  expect(app.texts().some(t => t.includes('"noteFormat":"rich-v1"') && t.includes('"source":"original"') && t.includes("中文追加"))).toBe(true);
});

test("colored rich note opens without saving or losing its color", async () => {
  const app = await open("../ui/notes/TestHarness.tsx", { width: 900, height: 900, platform: "macos" });
  await app.waitFor("id:note-rich-editor");
  await app.press("text:有损示例");
  await app.waitFor("text:保留颜色");
  await app.waitFor("id:note-rich-editor");
  expect(app.texts()).toContain("saves:0");
  await app.type("id:note-rich-editor", "追加");
  await app.wait(200);
  expect(app.texts().some(t => t.includes("#ff0000") && t.includes("追加"))).toBe(true);
});

test("legacy blank paragraphs stay intact on opening", async () => {
  const app = await open("../ui/notes/TestHarness.tsx", { width: 900, height: 900, platform: "macos" });
  await app.waitFor("id:note-rich-editor");
  await app.press("text:旧版示例");
  await app.waitFor("text:第一行");
  await app.waitFor("id:note-rich-editor");
  expect(app.texts()).toContain("saves:0");
  await app.type("id:note-rich-editor", "追加");
  await app.wait(200);
  expect(app.texts().some(t => t.includes('"id":"legacy"') && t.includes("追加"))).toBe(true);
});

import { createNoteSession, equivalent, storedDocument } from "../ui/notes/rich-session";
import { command, undo, redo, setTextSelection, insertTable } from "nsh/base";

test("official session preserves formatting, tables and attachment references", () => {
  const doc = clone(rich); delete doc.customVersion;
  doc.content!.pop();
  doc.content![0].content![0].marks = [{ type: "textStyle", attrs: { color: "#ff0000" } }, { type: "underline" }];
  for (const node of doc.content!) {
    try { createNoteSession({ type: "doc", content: [node] }); } catch (e) { throw Error(`Cannot preserve ${node.type}: ${String(e)}`); }
  }
  const editor = createNoteSession(doc);
  expect(equivalent(doc, storedDocument(editor.getJSON() as Node))).toBe(true);
});

test("unknown data is rejected instead of silently normalized away", () => {
  let rejected = false;
  try { createNoteSession(rich); } catch { rejected = true; }
  expect(rejected).toBe(true);
});

test("format commands and undo redo preserve the document", () => {
  const editor = createNoteSession({ type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "hello" }] }] });
  editor.setEditable(true);
  editor.run(setTextSelection(1, 6));
  editor.run(command("toggleBold"));
  const bold = editor.getJSON() as Node;
  expect(JSON.stringify(bold)).toContain('"bold"');
  editor.run(undo());
  expect(JSON.stringify(editor.getJSON())).not.toContain('"bold"');
  editor.run(redo());
  expect(editor.getJSON()).toEqual(bold);
  editor.run(insertTable({ rows: 2, cols: 2 }));
  expect(JSON.stringify(editor.getJSON())).toContain('"table"');
});
