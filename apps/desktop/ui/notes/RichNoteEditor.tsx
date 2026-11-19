import { effect, keymap, signal, View } from "nsh";
import { Input, TextView, RichEditor, command, undo, redo, insertTable, setTextSelection } from "nsh/base";
import { Menu } from "nsh/desktop";
import { Attachments, Files, NoteMarkdown, type Vault } from "passwordvault/native";
import { Icon, type IconName } from "../icons";
import { Btn, Row, T } from "../kit";
import { c, fs, MONO } from "../theme";
import { bumpNoteAssets } from "./NoteAssetsPanel";
import { patchFor, clone, documentFor, type Node, type Note, type Patch } from "./model";
import { project } from "./projection";
import { registerNoteCapture } from "./capture";
import { createNoteSession, equivalent, storedDocument } from "./rich-session";

export type RichNoteEditorProps = {
  item: Note;
  editable?: boolean;
  onChange: (patch: Patch, owner?: string) => void;
  vault?: Vault;
  wikilinkTargets?: string[];
  onMilestone?: () => void;
};
export function RichNoteEditor(props: RichNoteEditorProps) {
  const session = signal<ReturnType<typeof createNoteSession> | null>(null);
  const error = signal(""); const blocked = signal(false); const revision = signal(0);
  const panel = signal<"link" | "file" | "find" | "wikilink" | null>(null);
  const link = signal(""); const file = signal(""); const find = signal(""); const wikiQuery = signal(""); const busy = signal(false);
  let owner = "", initialized = false, origin: Note, alive = true, generation = 0;
  let last: Node | undefined, stop: (() => void) | undefined;
  const dismiss = () => panel.set(null);
  effect(() => registerNoteCapture(save));
  effect(() => () => { save(); alive = false; generation++; stop?.(); const old = session(); old?.setEditable(false); session.set(null); old?.dispose(); });
  effect(() => { if (panel() && props.editable) return keymap.bind("escape", dismiss); });
  effect(() => {
    const item = props.item;
    const externalUpdate =
      initialized &&
      owner === item.id &&
      item.noteFormat === "rich-v1" &&
      !!item.noteDocument &&
      !!last &&
      !equivalent(last, item.noteDocument);
    if (owner !== item.id || externalUpdate) {
      if (owner !== item.id) save();
      stop?.(); const old = session(); old?.setEditable(false); session.set(null); old?.dispose();
      owner = item.id; generation++; initialized = false; blocked.set(false); error.set(""); dismiss();
    }
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
  async function importFile(explicitPath?: string) {
    const target = explicitPath ?? file();
    if (!writable() || !props.vault || busy() || !target) return;
    const ticket = generation; busy.set(true);
    try {
      const meta = JSON.parse(await Attachments.importFile(props.vault, owner, target));
      if (!alive || ticket !== generation || !writable()) return;
      const image = meta.mime.startsWith("image/");
      const atom: Node = { type: image ? "vaultImage" : "vaultAttachment", attrs: { attachmentId: meta.id, name: meta.name, mime: meta.mime, ...(image ? { width: 600, caption: "" } : { size: meta.size }) } };
      const view = await loadImages({ type: "doc", content: [atom] }, props.vault, owner);
      if (!alive || ticket !== generation || !writable()) return;
      session()!.insertContent(view.content![0]); save(); bumpNoteAssets(); file.set(""); dismiss();
    } catch (e) { if (alive && ticket === generation) error.set(String(e)); }
    finally { if (alive) busy.set(false); }
  }
  async function pickAndImportFile() {
    if (!writable() || !props.vault || busy()) return;
    try {
      const picked = await Files.pickOpen("导入 PDF / Word / Excel / 图片（上限 100 MB）", []);
      if (picked && alive) await importFile(picked);
    } catch (e) {
      if (alive) error.set(String(e));
    }
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
  function insertWikilink(target: string) {
    const clean = target.trim();
    if (!clean || !writable()) return;
    session()!.insertContent({ type: "text", text: `[[${clean}]]` });
    save();
    wikiQuery.set("");
    dismiss();
    session()!.focus();
  }
  const wikiMatches = () => {
    const q = wikiQuery().trim().toLowerCase();
    return (props.wikilinkTargets ?? [])
      .filter((t) => !q || t.toLowerCase().includes(q))
      .slice(0, 6);
  };
  return <View style={{ gap: 0 }}>
    <If when={props.editable && !!session() && !blocked()}>
      <View role="toolbar" accessibilityLabel="笔记格式" style={{ flexDirection: "row", flexWrap: "wrap", alignItems: "center", minHeight: fs(34), gap: 2, paddingBottom: 6, borderBottomWidth: 1, borderBottomColor: c().line, marginBottom: 14 }}>
        <Tool label="段落样式" glyph="正文 ⌄" compactText disabled={!writable()} onPress={() => void Menu.popup([{ label: "正文", onSelect: () => run(command("setParagraph")) }, ...[1,2,3].map(level => ({ label: `标题 ${level}`, onSelect: () => run(command("toggleHeading", { level })) }))])} />
        <Divider />
        <Tool label="粗体" glyph="B" bold disabled={!writable()} onPress={() => run(command("toggleBold"))} />
        <Tool label="斜体" glyph="I" italic disabled={!writable()} onPress={() => run(command("toggleItalic"))} />
        <Tool label="下划线" glyph="U" underline disabled={!writable()} onPress={() => run(command("toggleUnderline"))} />
        <Tool label="删除线" glyph="S" strike disabled={!writable()} onPress={() => run(command("toggleStrike"))} />
        <Divider />
        <Tool label="项目列表" glyph="•≡" disabled={!writable()} onPress={() => run(command("toggleBulletList"))} />
        <Tool label="编号列表" glyph="1." disabled={!writable()} onPress={() => run(command("toggleOrderedList"))} />
        <Tool label="待办" glyph="☑" disabled={!writable()} onPress={() => run(command("toggleTaskList"))} />
        <Tool label="引用" glyph="❝" disabled={!writable()} onPress={() => run(command("toggleBlockquote"))} />
        <Tool label="代码块" glyph="{ }" compactText disabled={!writable()} onPress={() => run(command("toggleCodeBlock"))} />
        <Divider />
        <Tool label="链接" icon="link" disabled={!writable()} onPress={() => panel.set("link")} />
        <Tool label="插入双链 [[]]" glyph="[[]]" compactText disabled={!writable()} onPress={() => panel.set("wikilink")} />
        <Tool label="图片或附件" icon="paper" disabled={!writable() || !props.vault} onPress={() => panel.set("file")} />
        <Tool label="表格" icon="grid" disabled={!writable()} onPress={() => run(insertTable({ rows: 3, cols: 2, withHeaderRow: true }))} />
        <Divider />
        <Tool label="撤销" glyph="↶" disabled={!writable()} onPress={() => run(undo())} />
        <Tool label="重做" glyph="↷" disabled={!writable()} onPress={() => run(redo())} />
        <Tool label="查找" icon="search" onPress={() => panel.set("find")} />
        <If when={!!props.onMilestone}>
          <Divider />
          <Tool label="保存里程碑版本" icon="pin" glyph="里程碑" compactText disabled={!writable()} onPress={() => { save(); props.onMilestone?.(); }} />
        </If>
      </View>
      <If when={!!panel()}><View style={{ gap: 6, marginBottom: 12 }}>
        <Row>
          <If when={panel() === "link"}><Input value={link()} onChange={({ value }) => link.set(value)} placeholder="https:// 或 mailto: 链接" accessibilityLabel="笔记链接" style={{ flex: 1 }} /><Btn label="应用链接" onPress={() => { if (/^(https?:\/\/|mailto:)/i.test(link())) { run(command("setLink", { href: link() })); dismiss(); } }} /></If>
          <If when={panel() === "wikilink"}><Input value={wikiQuery()} onChange={({ value }) => wikiQuery.set(value)} placeholder="输入或选择要引用的笔记标题" accessibilityLabel="双链目标笔记" onSubmit={() => insertWikilink(wikiQuery())} style={{ flex: 1 }} /><Btn label="插入 [[]]" disabled={!wikiQuery().trim()} onPress={() => insertWikilink(wikiQuery())} /></If>
          <If when={panel() === "file"}><Btn label="选择本地文件…" kind="primary" disabled={busy()} onPress={() => void pickAndImportFile()} /><Input value={file()} onChange={({ value }) => file.set(value)} placeholder="或输入图片/PDF/Word 本地路径（上限 100 MB）" accessibilityLabel="附件文件路径" style={{ flex: 1 }} /><Btn label={busy() ? "导入中…" : "导入"} disabled={busy() || !file()} onPress={() => void importFile()} /></If>
          <If when={panel() === "find"}><Input value={find()} onChange={({ value }) => find.set(value)} placeholder="查找正文" accessibilityLabel="查找笔记正文" style={{ flex: 1 }} /><Btn label="查找下一个" onPress={findNext} /></If>
          <Tool label="取消" icon="x" onPress={dismiss} />
        </Row>
        <If when={panel() === "wikilink" && wikiMatches().length > 0}>
          <Row gap={6} wrap>
            {wikiMatches().map((title) => (
              <Btn label={`[[${title}]]`} kind="ghost" onPress={() => insertWikilink(title)} />
            ))}
          </Row>
        </If>
      </View></If>
    </If>
    <If when={!!error()}><T color={c().red}>{error()}</T></If>
    <If when={!!session()} else={<TextView document={props.item.noteDocument ? project(props.item.noteDocument) : project(documentFor({ id: props.item.id, note: props.item.note, noteFormat: "plain" }))} links="report" onLinkPress={() => {}} />}>
      <Each of={session() ? [session()!] : []} key={editor => editor}>{editor => <RichEditor editor={editor()} editable={!!props.editable && !blocked()} testID="note-rich-editor" accessibilityLabel="笔记正文" onChange={save} onBlur={save}
        style={{ height: 520 }}
        styles={{
          content: { fontSize: fs(14.5), lineHeight: fs(25), color: c().ink, paddingVertical: 8, paddingHorizontal: 2 },
          listMarker: { color: c().muted },
          taskCheckbox: { width: 16, height: 16, marginRight: 8, borderWidth: 1, borderColor: c().line, borderRadius: 3 },
          nodes: {
            paragraph: { fontSize: fs(14.5), lineHeight: fs(25), marginTop: 0, marginBottom: 10, color: c().ink },
            "heading[level=1]": { fontSize: fs(21), lineHeight: fs(30), fontWeight: "700", marginTop: 8, marginBottom: 12, color: c().ink },
            "heading[level=2]": { fontSize: fs(17.5), lineHeight: fs(26), fontWeight: "600", marginTop: 22, marginBottom: 8, color: c().ink },
            "heading[level=3]": { fontSize: fs(15.5), lineHeight: fs(24), fontWeight: "600", marginTop: 16, marginBottom: 6, color: c().ink },
            blockquote: {
              borderLeftWidth: 3,
              borderLeftColor: c().blueLine,
              backgroundColor: c().soft2,
              borderRadius: 6,
              paddingLeft: 14,
              paddingRight: 12,
              paddingVertical: 8,
              marginTop: 6,
              marginBottom: 14,
              color: c().ink2,
              lineHeight: fs(23),
            },
            bulletList: { paddingLeft: 20, marginTop: 2, marginBottom: 12 },
            orderedList: { paddingLeft: 20, marginTop: 2, marginBottom: 12 },
            taskList: { paddingLeft: 4, marginTop: 2, marginBottom: 12 },
            listItem: { lineHeight: fs(24), marginBottom: 5 },
            codeBlock: { backgroundColor: c().soft2, borderWidth: 1, borderColor: c().line, padding: 12, borderRadius: 8, marginTop: 6, marginBottom: 14, fontFamily: MONO, fontSize: fs(13), lineHeight: fs(21) },
            horizontalRule: { borderBottomWidth: 1, borderBottomColor: c().line, marginVertical: 16 },
            tableCell: { borderWidth: 1, borderColor: c().line, padding: 8, fontSize: fs(13), lineHeight: fs(20) },
            tableHeader: { borderWidth: 1, borderColor: c().line, padding: 8, backgroundColor: c().soft2, fontWeight: "600", fontSize: fs(12.5), lineHeight: fs(20) },
          },
          marks: {
            code: { fontFamily: MONO, fontSize: fs(13), backgroundColor: c().soft2, color: c().blue, paddingHorizontal: 4, borderRadius: 4 },
            link: { color: c().blue },
          },
        }}
        classes={{
          taskCheckbox: "checked:bg-blue-500",
          nodes: { heading: "font-bold", codeBlock: "font-mono" },
          marks: { bold: "font-bold", italic: "italic", underline: "underline", strike: "line-through" },
        }}
      />}</Each>
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
function Divider() { return <View style={{ width: 1, height: 14, backgroundColor: c().line, marginHorizontal: 3 }} />; }
function Tool(props: { label: string; glyph?: string; icon?: IconName; onPress: () => void; disabled?: boolean; selected?: boolean; compactText?: boolean; bold?: boolean; italic?: boolean; underline?: boolean; strike?: boolean }) {
  return <View role="button" accessibilityLabel={props.label} tooltip={props.label} accessibilityState={{ disabled: !!props.disabled }} onPress={props.disabled ? undefined : props.onPress}
    style={{ flexDirection: "row", gap: 4, minWidth: 26, height: 26, paddingHorizontal: props.compactText ? 7 : 5, borderRadius: 5, alignItems: "center", justifyContent: "center", cursor: props.disabled ? "default" : "pointer", opacity: props.disabled ? 0.4 : 1, backgroundColor: props.selected ? c().blueSoft : "transparent" }}
    hoverStyle={{ backgroundColor: c().field }}>
    <If when={!!props.icon}>
      <Icon name={props.icon!} size={13} tint={props.selected ? c().blue : c().ink2} />
    </If>
    <If when={!!props.glyph}>
      <T size={props.compactText ? 11.5 : 13} weight={props.bold ? "700" : "500"} color={props.selected ? c().blue : c().ink2} style={{ fontStyle: props.italic ? "italic" : "normal", textDecorationLine: props.underline ? "underline" : props.strike ? "line-through" : "none" }}>{props.glyph}</T>
    </If>
  </View>;
}
