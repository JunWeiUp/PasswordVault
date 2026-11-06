// Headless fixture; never imported by App.tsx.
import { mount, signal, Text, View } from "nsh";
import { RichNoteEditor } from "./RichNoteEditor";
import { Btn } from "../kit";
import type { Note } from "./model";
const item = signal<Note>({ id: "synthetic-note-editor", noteFormat: "plain", note: "original" });
const editing = signal(true);
const saves = signal(0);
mount(() => <View><RichNoteEditor item={item()} editable={editing()} onChange={patch => { saves.update(n => n + 1); item.update(i => ({ ...i, ...patch })); }} /><Btn label="预览" onPress={() => editing.set(false)} /><Btn label="有损示例" onPress={() => { saves.set(0); editing.set(true); item.set({ id: "lossy", noteFormat: "rich-v1", note: "保留颜色", noteDocument: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "保留颜色", marks: [{ type: "textStyle", attrs: { color: "#ff0000" } }] }] }] } }); }} /><Btn label="旧版示例" onPress={() => { saves.set(0); editing.set(true); item.set({ id: "legacy", noteFormat: "rich-v1", note: "第一行\n\n第二行", noteDocument: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "第一行" }] }, { type: "paragraph" }, { type: "paragraph", attrs: { textAlign: null }, content: [{ type: "text", text: "  第二行" }, { type: "hardBreak" }] }, { type: "paragraph" }] } }); }} /><Text>{`saves:${saves()}`}</Text><Text testID="note-result">{JSON.stringify(item())}</Text></View>);
