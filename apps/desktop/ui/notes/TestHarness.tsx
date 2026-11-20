// Headless fixture; never imported by App.tsx.
import { mount, signal, Text, View } from "nsh";
import { RichNoteEditor } from "./RichNoteEditor";
import { Btn } from "../kit";
import type { Note } from "./model";
const item = signal<Note>({ id: "synthetic-note-editor", noteFormat: "plain", note: "original" });
const editing = signal(true);
const saves = signal(0);
const multilineDoc = {
  type: "doc",
  content: [
    { type: "heading", attrs: { level: 2 }, content: [{ type: "text", text: "账号与接口说明" }] },
    { type: "paragraph", content: [{ type: "text", text: "这是一段非常长的测试正文，用来验证开启行号时自动换行不会产生重复行号，并且下一行的行号会精确对齐到下一个逻辑段落的起始位置，同时窗口宽度变化时也能自动重新对齐。" }] },
    { type: "paragraph" },
    { type: "codeBlock", attrs: { language: "text" }, content: [{ type: "text", text: "line_a = 1\nline_b = 2\nline_c = 3" }] },
    { type: "paragraph", content: [{ type: "text", text: "结尾行" }] },
  ],
};
mount(() => <View><RichNoteEditor item={item()} editable={editing()} onChange={patch => { saves.update(n => n + 1); item.update(i => ({ ...i, ...patch })); }} /><Btn label="预览" onPress={() => editing.set(false)} /><Btn label="有损示例" onPress={() => { saves.set(0); editing.set(true); item.set({ id: "lossy", noteFormat: "rich-v1", note: "保留颜色", noteDocument: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "保留颜色", marks: [{ type: "textStyle", attrs: { color: "#ff0000" } }] }] }] } }); }} /><Btn label="旧版示例" onPress={() => { saves.set(0); editing.set(true); item.set({ id: "legacy", noteFormat: "rich-v1", note: "第一行\n\n第二行", noteDocument: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "第一行" }] }, { type: "paragraph" }, { type: "paragraph", attrs: { textAlign: null }, content: [{ type: "text", text: "  第二行" }, { type: "hardBreak" }] }, { type: "paragraph" }] } }); }} /><Btn label="多行代码示例" onPress={() => { saves.set(0); editing.set(true); item.set({ id: "multiline-code", noteFormat: "rich-v1", note: "账号与接口说明", noteDocument: multilineDoc }); }} /><Text>{`saves:${saves()}`}</Text><Text testID="note-result">{JSON.stringify(item())}</Text></View>);
