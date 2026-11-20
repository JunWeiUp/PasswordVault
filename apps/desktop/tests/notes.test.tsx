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
import {
  activeLineAt,
  extractLineAnchors,
  gutterMetrics,
  measureLineAnchors,
  nodeSize,
  sameMeasuredLines,
} from "../ui/notes/line-numbers";

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

test("adjacent Markdown text spans normalize without relaxing content preservation", () => {
  const split: Node = { type: "doc", content: [{ type: "paragraph", content: [
    { type: "text", text: "紧急联系" }, { type: "text", text: "\n" }, { type: "text", text: "• 家庭邮箱：" },
    { type: "text", text: "family@example.com", marks: [{ type: "link", attrs: { href: "mailto:family@example.com" } }] },
    { type: "text", text: "\n" }, { type: "text", text: "• 示例联系人" },
  ] }] };
  const before = clone(split);
  const editor = createNoteSession(split);
  expect(equivalent(split, editor.getJSON() as Node)).toBe(true);
  expect(split).toEqual(before);
  editor.dispose();
  const changed = clone(split); changed.content![0].content![0].text = "changed";
  expect(equivalent(split, changed)).toBe(false);
  const changedMarks = clone(split); changedMarks.content![0].content![0].marks = [{ type: "bold" }];
  expect(equivalent(split, changedMarks)).toBe(false);
  const unknown = clone(split); (unknown.content![0].content![0] as any).futureMetadata = 42;
  expect(equivalent(split, unknown)).toBe(false);
});

test("line-number helpers compute exact ProseMirror anchors, gutter widths and active lines", () => {
  const doc: Node = {
    type: "doc",
    content: [
      { type: "heading", attrs: { level: 1 }, content: [{ type: "text", text: "标题😀" }] }, // pos 0, size 2+4=6, content 1..5
      { type: "paragraph" }, // pos 6, size 2, content 7..7
      { type: "paragraph", content: [{ type: "text", text: "第一" }, { type: "hardBreak" }, { type: "text", text: "第二" }] }, // pos 8, size 2+5=7
      { type: "codeBlock", content: [{ type: "text", text: "a\nb\nc" }] }, // pos 15, size 2+5=7
      { type: "bulletList", content: [{ type: "listItem", content: [{ type: "paragraph", content: [{ type: "text", text: "项" }] }] }] },
      { type: "horizontalRule" },
      {
        type: "table",
        content: [
          { type: "tableRow", content: [{ type: "tableHeader", content: [{ type: "paragraph", content: [{ type: "text", text: "H1" }] }] }, { type: "tableHeader", content: [{ type: "paragraph", content: [{ type: "text", text: "H2" }] }] }] },
          { type: "tableRow", content: [{ type: "tableCell", content: [{ type: "paragraph", content: [{ type: "text", text: "A" }] }] }, { type: "tableCell", content: [{ type: "paragraph", content: [{ type: "text", text: "B" }] }] }] },
        ],
      },
      { type: "vaultImage", attrs: { attachmentId: "img-1", name: "photo.png" } },
    ],
  };

  expect(nodeSize(doc.content![0])).toBe(6);
  expect(nodeSize(doc.content![1])).toBe(2);
  expect(nodeSize(doc.content![5])).toBe(1);

  const anchors = extractLineAnchors(doc);
  // 1 heading + 1 blank para + 2 hardBreak lines + 3 code lines + 1 list item + 1 hr + 2 table rows + 1 image = 12
  expect(anchors.length).toBe(12);
  expect(anchors[0]).toMatchObject({ line: 1, pos: 1, from: 1, to: 5, measure: "caret" });
  expect(anchors[1]).toMatchObject({ line: 2, pos: 7, from: 7, to: 7, measure: "caret" });
  expect(anchors[2]).toMatchObject({ line: 3, pos: 9, from: 9, to: 11, measure: "caret" });
  expect(anchors[3]).toMatchObject({ line: 4, pos: 12, from: 12, to: 14, measure: "caret" });
  expect(anchors[4]).toMatchObject({ line: 5, pos: 16, from: 16, to: 17, measure: "caret" });
  expect(anchors[5]).toMatchObject({ line: 6, pos: 18, from: 18, to: 19, measure: "caret" });
  expect(anchors[6]).toMatchObject({ line: 7, pos: 20, from: 20, to: 21, measure: "caret" });
  expect(anchors[8]).toMatchObject({ line: 9, measure: "node" });
  expect(anchors[11]).toMatchObject({ line: 12, measure: "node" });

  // Measure with simulated rects, including tall image clamping, thin HR centering and same-y dedup.
  const measured = measureLineAnchors(
    [
      { line: 1, pos: 1, from: 1, to: 5, measure: "caret" },
      { line: 2, pos: 6, from: 6, to: 6, measure: "caret" }, // same y as line 1 -> deduped
      { line: 3, pos: 8, from: 8, to: 9, measure: "node" }, // thin rule
      { line: 4, pos: 10, from: 10, to: 11, measure: "node" }, // tall image
    ],
    {
      coordsAtPos: (pos) => (pos <= 6 ? { x: 47, y: 8, width: 0, height: 25 } : null),
      nodeRect: (pos) =>
        pos === 8 ? { x: 47, y: 50, width: 600, height: 1 } : { x: 47, y: 80, width: 400, height: 240 },
    },
    25,
  );
  expect(measured.length).toBe(3);
  expect(measured[0]).toEqual({ line: 1, top: 8, height: 25, from: 1, to: 6 });
  expect(measured[1]).toEqual({ line: 2, top: 38, height: 25, from: 8, to: 9 });
  expect(measured[2]).toEqual({ line: 3, top: 80, height: 25, from: 10, to: 11 });
  expect(sameMeasuredLines(measured, clone(measured))).toBe(true);
  expect(activeLineAt(measured, 4)).toBe(1);
  expect(activeLineAt(measured, 8)).toBe(2);
  expect(activeLineAt(measured, 10)).toBe(3);

  const codeAnchors = extractLineAnchors({
    type: "doc",
    content: [{ type: "codeBlock", content: [{ type: "text", text: "a\nb\nc" }] }],
  });
  const codeMeasured = measureLineAnchors(
    codeAnchors,
    {
      coordsAtPos: (pos) => ({ x: 47, y: 20 + Math.floor((pos - 1) / 2) * 21, width: 0, height: 21 }),
      nodeRect: () => null,
    },
    25,
  );
  expect(codeMeasured.map((r) => `${r.line}:${r.top}`)).toEqual(["1:20", "2:41", "3:62"]);

  const m2 = gutterMetrics(9, (n) => n);
  const m3 = gutterMetrics(120, (n) => n);
  const m4 = gutterMetrics(1500, (n) => n);
  expect(m2.digits).toBe(2);
  expect(m3.digits).toBe(3);
  expect(m4.digits).toBe(4);
  expect(m3.contentPaddingLeft).toBeGreaterThan(m2.contentPaddingLeft);
  expect(m4.contentPaddingLeft).toBeGreaterThan(m3.contentPaddingLeft);
});

test("RichNoteEditor shows line numbers and toggles them off and on cleanly", async () => {
  const app = await open("../ui/notes/TestHarness.tsx", { width: 900, height: 900, platform: "macos" });
  await app.waitFor("id:note-rich-editor");
  await app.waitFor("id:note-line-gutter");
  await app.waitFor("id:note-line-num-1");

  // Multi-line fixture ("旧版示例") displays sequential line numbers for paragraphs and blank lines.
  await app.press("text:旧版示例");
  await app.waitFor("text:第一行");
  await app.waitFor("id:note-line-num-4");
  expect(app.shows("id:note-line-num-1")).toBe(true);
  expect(app.shows("id:note-line-num-2")).toBe(true);
  expect(app.shows("id:note-line-num-3")).toBe(true);
  expect(app.shows("id:note-line-num-4")).toBe(true);

  // Toggle line numbers OFF via toolbar button.
  await app.press("id:note-line-numbers-toggle");
  await app.waitFor("id:note-line-gutter", { state: "gone" });
  expect(app.shows("id:note-line-num-1")).toBe(false);
  expect(app.storage().noteLineNumbers).toBe("0");

  // Toggle line numbers back ON via toolbar button.
  await app.press("id:note-line-numbers-toggle");
  await app.waitFor("id:note-line-gutter");
  await app.waitFor("id:note-line-num-4");
  expect(app.storage().noteLineNumbers).toBe("1");

  // Multi-line wrapped paragraph + blank line + 3-line codeBlock + trailing paragraph.
  // In headless mode (no CoreText TextLayout), codeBlock reports a single block y so dedup yields 5 non-overlapping lines.
  await app.press("text:多行代码示例");
  await app.waitFor("text:账号与接口说明");
  await app.waitFor("id:note-line-num-5");
  expect(app.shows("id:note-line-num-1")).toBe(true);
  expect(app.shows("id:note-line-num-5")).toBe(true);

  // Narrow viewport forces re-wrap; gutter and all line numbers stay rendered cleanly.
  await app.setViewport(480, 900);
  await app.wait(120);
  expect(app.shows("id:note-line-gutter")).toBe(true);
  expect(app.shows("id:note-line-num-5")).toBe(true);
});
