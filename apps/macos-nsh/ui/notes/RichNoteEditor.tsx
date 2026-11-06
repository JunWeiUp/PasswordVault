import { effect, keymap, signal, View } from "nsh";
import { Input, TextView, RichEditor, command, undo, redo, insertTable, setTextSelection } from "nsh/base";
import { Menu } from "nsh/desktop";
import { Attachments, NoteMarkdown, type Vault } from "passwordvault/native";
import { Btn, Row, T } from "../kit";
import { c, fs } from "../theme";
import { patchFor, clone, type Node, type Note, type Patch } from "./model";
import { project } from "./projection";
import { registerNoteCapture } from "./capture";
import { createNoteSession, equivalent, storedDocument } from "./rich-session";

export type RichNoteEditorProps = { item: Note; editable?: boolean; onChange: (patch: Patch, owner?: string) => void; vault?: Vault };
export function RichNoteEditor(props: RichNoteEditorProps) {
  const session = signal<ReturnType<typeof createNoteSession> | null>(null);
  const error = signal(""); const blocked = signal(false); const revision = signal(0);
  const panel = signal<"link" | "file" | "find" | null>(null);
  const link = signal(""); const file = signal(""); const find = signal(""); const busy = signal(false);
  let owner = "", initialized = false, origin: Note, alive = true, generation = 0;
  let last: Node | undefined, stop: (() => void) | undefined;
  const dismiss = () => panel.set(null);
  effect(() => registerNoteCapture(save));
  effect(() => () => { save(); alive = false; generation++; stop?.(); const old = session(); old?.setEditable(false); session.set(null); old?.dispose(); });
  effect(() => { if (panel() && props.editable) return keymap.bind("escape", dismiss); });
  effect(() => {
    const item = props.item;
    if (owner !== item.id) { save(); stop?.(); const old = session(); old?.setEditable(false); session.set(null); old?.dispose(); owner = item.id; generation++; initialized = false; blocked.set(false); error.set(""); dismiss(); }
    if (initialized || (item.noteFormat === "rich-v1" && !item.noteDocument)) return;
    initialized = true;
    origin = { id: item.id, note: item.note, noteFormat: item.noteFormat, noteOriginal: item.noteOriginal };
    const ticket = generation;
    try {
      const doc: Node = item.noteFormat === "rich-v1" ? clone(item.noteDocument!) : JSON.parse(NoteMarkdown.fromMarkdown(item.note ?? "")).noteDocument;
      // Validate before loading any resource. Unknown data never silently disappears.
      createNoteSession(doc).dispose(); // Validate without retaining a second native document.
      void loadImages(doc, props.vault, item.id).then(viewDoc => {
        if (!alive || ticket !== generation) return;
        const editor = createNoteSession(doc, viewDoc);
        last = storedDocument(editor.getJSON() as Node);
        session.set(editor);
        stop = editor.on("revision", () => {
          if (!alive || ticket !== generation) return;
          revision.update(n => n + 1); save();
        });
      }).catch(e => { if (alive && ticket === generation) { blocked.set(true); error.set(String(e)); } });
    } catch (e) { blocked.set(true); error.set(String(e)); }
  });
  effect(() => { if (!props.editable) save(); session()?.setEditable(!!props.editable && !blocked()); });
  function save() {
    const editor = session();
    if (!editor || !alive || blocked() || editor.composing) return;
    try {
      const doc = storedDocument(editor.getJSON() as Node);
      if (last && equivalent(last, doc)) return;
      last = doc; props.onChange(patchFor(origin, doc), owner); error.set("");
    } catch (e) { error.set(`正文尚未保存：${String(e)}`); }
  }
  const writable = () => { revision(); return !!props.editable && !!session() && !blocked() && !session()!.composing; };
  function run(action: any) { if (writable()) { session()!.run(action); save(); session()!.focus(); } }
  async function importFile() {
    if (!writable() || !props.vault || busy() || !file()) return;
    const ticket = generation; busy.set(true);
    try {
      const meta = JSON.parse(await Attachments.importFile(props.vault, owner, file()));
      if (!alive || ticket !== generation || !writable()) return;
      const image = meta.mime.startsWith("image/");
      const atom: Node = { type: image ? "vaultImage" : "vaultAttachment", attrs: { attachmentId: meta.id, name: meta.name, mime: meta.mime, ...(image ? { width: 600, caption: "" } : { size: meta.size }) } };
      const view = await loadImages({ type: "doc", content: [atom] }, props.vault, owner);
      if (!alive || ticket !== generation || !writable()) return;
      session()!.insertContent(view.content![0]); save(); file.set(""); dismiss();
    } catch (e) { if (alive && ticket === generation) error.set(String(e)); }
    finally { if (alive) busy.set(false); }
  }
  function findNext() {
    const editor = session(); if (!editor || !find()) return;
    const hits: number[] = []; let offset = 0;
    function visit(n: Node, root = false) {
      if (n.type === "text") { let i = n.text!.indexOf(find()); while (i >= 0) { hits.push(offset + i); i = n.text!.indexOf(find(), i + 1); } offset += n.text!.length; }
      else if (!n.content) offset += 1;
      else { if (!root) offset++; n.content.forEach(child => visit(child)); if (!root) offset++; }
    }
    visit(editor.getJSON() as Node, true);
    const pos = hits.find(p => p >= (editor.selection as any).to) ?? hits[0];
    if (pos !== undefined) { editor.run(setTextSelection(pos, pos + find().length)); editor.focus(); }
  }
  return <View style={{ gap: 0 }}>
    <If when={props.editable && !!session() && !blocked()}>
      <View role="toolbar" accessibilityLabel="笔记格式" style={{ flexDirection: "row", flexWrap: "wrap", alignItems: "center", minHeight: fs(33), gap: 2, borderBottomWidth: 1, borderBottomColor: c().line, marginBottom: 10 }}>
        <Tool label="段落样式" glyph="正文 ⌄" wide disabled={!writable()} onPress={() => void Menu.popup([{ label: "正文", onSelect: () => run(command("setParagraph")) }, ...[1,2,3].map(level => ({ label: `标题 ${level}`, onSelect: () => run(command("toggleHeading", { level })) }))])} />
        <Divider />
        {[["粗体", "B", "toggleBold"], ["斜体", "I", "toggleItalic"], ["下划线", "U", "toggleUnderline"], ["删除线", "S", "toggleStrike"], ["项目列表", "• ≡", "toggleBulletList"], ["编号列表", "1. ≡", "toggleOrderedList"], ["待办", "☑", "toggleTaskList"], ["引用", "❝", "toggleBlockquote"], ["代码块", "‹ ›", "toggleCodeBlock"]].map(([label, glyph, name]) => <Tool label={label} glyph={glyph} disabled={!writable()} onPress={() => run(command(name))} />)}
        <Tool label="链接" glyph="↗" disabled={!writable()} onPress={() => panel.set("link")} />
        <Tool label="图片或附件" glyph="▧" disabled={!writable() || !props.vault} onPress={() => panel.set("file")} />
        <Tool label="表格" glyph="▦" disabled={!writable()} onPress={() => run(insertTable({ rows: 3, cols: 2, withHeaderRow: true }))} />
        <Tool label="撤销" glyph="↶" disabled={!writable()} onPress={() => run(undo())} />
        <Tool label="重做" glyph="↷" disabled={!writable()} onPress={() => run(redo())} />
        <Tool label="查找" glyph="⌕" onPress={() => panel.set("find")} />
      </View>
      <If when={!!panel()}><Row style={{ marginBottom: 12 }}>
        <If when={panel() === "link"}><Input value={link()} onChange={({ value }) => link.set(value)} placeholder="https:// 或 mailto: 链接" accessibilityLabel="笔记链接" style={{ flex: 1 }} /><Btn label="应用链接" onPress={() => { if (/^(https?:\/\/|mailto:)/i.test(link())) { run(command("setLink", { href: link() })); dismiss(); } }} /></If>
        <If when={panel() === "file"}><Input value={file()} onChange={({ value }) => file.set(value)} placeholder="图片或附件的本地路径" accessibilityLabel="附件文件路径" style={{ flex: 1 }} /><Btn label={busy() ? "导入中…" : "导入"} disabled={busy()} onPress={() => void importFile()} /></If>
        <If when={panel() === "find"}><Input value={find()} onChange={({ value }) => find.set(value)} placeholder="查找正文" accessibilityLabel="查找笔记正文" style={{ flex: 1 }} /><Btn label="查找下一个" onPress={findNext} /></If>
        <Tool label="取消" glyph="×" onPress={dismiss} />
      </Row></If>
    </If>
    <If when={!!error()}><T color={c().red}>{error()}</T></If>
    <If when={!!session()} else={<TextView document={props.item.noteDocument ? project(props.item.noteDocument) : { blocks: [] }} links="report" onLinkPress={() => {}} />}>
      <Each of={session() ? [session()!] : []} key={editor => editor}>{editor => <RichEditor editor={editor()} editable={!!props.editable && !blocked()} testID="note-rich-editor" accessibilityLabel="笔记正文" onChange={save} onBlur={save}
        style={{ height: 480 }} styles={{ content: { fontSize: fs(14.5), color: c().ink },
          taskCheckbox: { width: 16, height: 16, marginRight: 8, borderWidth: 1, borderColor: c().line, borderRadius: 3 },
          nodes: { "heading[level=1]": { fontSize: fs(28) }, "heading[level=2]": { fontSize: fs(23) }, "heading[level=3]": { fontSize: fs(19) },
            codeBlock: { backgroundColor: c().soft2, padding: 12, borderRadius: 6 },
            tableCell: { borderWidth: 1, borderColor: c().line, padding: 8 }, tableHeader: { borderWidth: 1, borderColor: c().line, padding: 8, backgroundColor: c().soft2, fontWeight: "600" } } }} classes={{ content: "py-2 gap-3", taskCheckbox: "checked:bg-blue-500", nodes: { heading: "font-bold", codeBlock: "font-mono", blockquote: "pl-4 border-l-2", bulletList: "pl-5", orderedList: "pl-5" }, marks: { bold: "font-bold", italic: "italic", underline: "underline", strike: "line-through" } }} />}</Each>
    </If>
  </View>;
}
async function loadImages(doc: Node, vault: Vault | undefined, owner: string): Promise<Node> {
  const view = clone(doc);
  async function visit(n: Node): Promise<void> {
    if (n.type === "vaultImage" && n.attrs) { n.attrs.src = ""; n.attrs.alt = n.attrs.caption || n.attrs.name || "图片"; if (vault) n.attrs.src = await Attachments.readImage(vault, owner, n.attrs.attachmentId); }
    for (const child of n.content ?? []) await visit(child);
  }
  await visit(view); return view;
}
function Divider() { return <View style={{ width: 1, height: 15, backgroundColor: c().line, marginHorizontal: 5 }} />; }
function Tool(props: { label: string; glyph: string; onPress: () => void; disabled?: boolean; selected?: boolean; wide?: boolean; bold?: boolean; italic?: boolean; underline?: boolean; strike?: boolean }) {
  return <View role="button" accessibilityLabel={props.label} tooltip={props.label} accessibilityState={{ disabled: !!props.disabled }} onPress={props.disabled ? undefined : props.onPress}
    style={{ width: props.wide ? 80 : 28, height: 28, borderRadius: 4, alignItems: "center", justifyContent: "center", cursor: props.disabled ? "default" : "pointer", opacity: props.disabled ? 0.4 : 1, backgroundColor: props.selected ? c().blueSoft : "transparent" }}
    hoverStyle={{ backgroundColor: c().field }}>
    <T size={props.wide ? 12 : 14} weight={props.bold ? "700" : "400"} color={props.selected ? c().blue : c().ink2} style={{ fontStyle: props.italic ? "italic" : "normal", textDecorationLine: props.underline ? "underline" : props.strike ? "line-through" : "none" }}>{props.glyph}</T>
  </View>;
}
