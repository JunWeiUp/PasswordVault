import { effect, keymap, signal, View } from "nsh";
import { Input, TextView, RichEditor, command, undo, redo, insertTable, setTextSelection } from "nsh/base";
import { Attachments, Files, NoteMarkdown, type Vault } from "passwordvault/native";
import { Icon, type IconName } from "../icons";
import { Btn, Pill, Row, T } from "../kit";
import { noteLineNumbers, setNoteLineNumbers } from "../preferences";
import { c, fs, MONO, textScale } from "../theme";
import { assetErrorText, readImageThumbnail, requestRemoteAsset } from "../api/noteAssets";
import { bumpNoteAssets } from "./NoteAssetsPanel";
import {
  activeLineAt,
  extractLineAnchors,
  gutterMetrics,
  measureLineAnchors,
  sameMeasuredLines,
  type MeasuredLine,
} from "./line-numbers";
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
  onOpenHistory?: () => void;
  showLineNumbers?: boolean;
  onToggleLineNumbers?: () => void;
};

type ImageLoadItem = {
  attachmentId: string;
  name: string;
  status: "loading" | "l2" | "l3" | "failed";
  error?: string;
};

function collectVaultImages(node: Node, out: { attachmentId: string; name: string }[] = []): { attachmentId: string; name: string }[] {
  if (node.type === "vaultImage" && node.attrs?.attachmentId) {
    out.push({ attachmentId: String(node.attrs.attachmentId), name: String(node.attrs.name || node.attrs.caption || "图片") });
  }
  for (const child of node.content ?? []) collectVaultImages(child, out);
  return out;
}

function makePlaceholderViewDoc(doc: Node): Node {
  const view = clone(doc);
  function visit(n: Node) {
    if (n.type === "vaultImage" && n.attrs) {
      n.attrs.src = "";
      n.attrs.alt = n.attrs.caption || n.attrs.name || "加载预览图中…";
    }
    for (const child of n.content ?? []) visit(child);
  }
  visit(view);
  return view;
}

function patchImageSrcsInDoc(doc: Node, srcMap: Map<string, string>, altMap?: Map<string, string>): boolean {
  let changed = false;
  function visit(n: Node) {
    if (n.type === "vaultImage" && n.attrs?.attachmentId) {
      const id = String(n.attrs.attachmentId);
      const nextSrc = srcMap.get(id);
      if (nextSrc !== undefined && n.attrs.src !== nextSrc) {
        n.attrs.src = nextSrc;
        changed = true;
      }
      const nextAlt = altMap?.get(id);
      if (nextAlt !== undefined && n.attrs.alt !== nextAlt) {
        n.attrs.alt = nextAlt;
        changed = true;
      }
    }
    for (const child of n.content ?? []) visit(child);
  }
  visit(doc);
  return changed;
}

export function RichNoteEditor(props: RichNoteEditorProps) {
  const session = signal<ReturnType<typeof createNoteSession> | null>(null);
  const error = signal(""); const blocked = signal(false); const revision = signal(0);
  const panel = signal<"link" | "file" | "find" | "wikilink" | null>(null);
  const link = signal(""); const file = signal(""); const find = signal(""); const wikiQuery = signal(""); const busy = signal(false);
  const measuredLines = signal<MeasuredLine[]>([]);
  const anchorCount = signal(1);
  const selectionHead = signal<number | null>(null);
  const imageStates = signal<ImageLoadItem[]>([]);
  const upgradingOrig = signal(false);
  const pendingExternal = signal<Note | null>(null);
  let owner = "", initialized = false, origin: Note, alive = true, generation = 0;
  let last: Node | undefined, stop: (() => void) | undefined, stopSel: (() => void) | undefined;
  let measureTimer: ReturnType<typeof setTimeout> | null = null;
  let retryTimer: ReturnType<typeof setTimeout> | null = null;
  let saveTimer: ReturnType<typeof setTimeout> | null = null;
  let localDirty = false;
  let applyingInternal = false;
  const dismiss = () => panel.set(null);
  const showLineNumbers = () => props.showLineNumbers ?? noteLineNumbers();
  const toggleLineNumbers = () => {
    if (props.onToggleLineNumbers) props.onToggleLineNumbers();
    else setNoteLineNumbers(!showLineNumbers());
  };
  const clearMeasureTimers = () => {
    if (measureTimer !== null) { clearTimeout(measureTimer); measureTimer = null; }
    if (retryTimer !== null) { clearTimeout(retryTimer); retryTimer = null; }
  };
  const clearSaveTimer = () => {
    if (saveTimer !== null) { clearTimeout(saveTimer); saveTimer = null; }
  };
  const measureNow = (allowRetry = false) => {
    const editor = session();
    if (!alive || !editor || !showLineNumbers()) {
      if (measuredLines().length > 0) measuredLines.set([]);
      return;
    }
    try {
      const doc = editor.getJSON() as Node;
      const anchors = extractLineAnchors(doc);
      anchorCount.set(Math.max(1, anchors.length));
      const next = measureLineAnchors(anchors, editor, fs(25), selectionHead());
      if (next.length === 0 && anchors.length > 0) {
        if (allowRetry && retryTimer === null) {
          retryTimer = setTimeout(() => { retryTimer = null; measureNow(false); }, 80);
        }
        return;
      }
      if (!sameMeasuredLines(measuredLines(), next)) measuredLines.set(next);
      if (next.length < Math.min(anchors.length, 240) && allowRetry && retryTimer === null) {
        retryTimer = setTimeout(() => { retryTimer = null; measureNow(false); }, 80);
      }
    } catch {
      // Transient state while switching documents; next layout event will re-measure.
    }
  };
  const scheduleMeasure = (delay = 60) => {
    if (!alive || !showLineNumbers()) return;
    if (measureTimer !== null) clearTimeout(measureTimer);
    measureTimer = setTimeout(() => {
      measureTimer = null;
      measureNow(true);
    }, delay);
  };
  const scheduleSave = (delay = 300) => {
    clearSaveTimer();
    saveTimer = setTimeout(() => {
      saveTimer = null;
      save();
    }, delay);
  };
  const metrics = () => gutterMetrics(Math.max(measuredLines().length, anchorCount()), fs);
  const activeLine = () => activeLineAt(measuredLines(), selectionHead());
  effect(() => registerNoteCapture(save));
  effect(() => () => {
    clearSaveTimer(); save(); alive = false; generation++; clearMeasureTimers();
    stop?.(); stopSel?.();
    const old = session(); old?.setEditable(false); session.set(null); old?.dispose();
  });
  effect(() => { if (panel() && props.editable) return keymap.bind("escape", dismiss); });

  const applyImagePatches = (ticket: number, srcMap: Map<string, string>, altMap?: Map<string, string>) => {
    const editor = session();
    if (!alive || ticket !== generation || !editor || editor.composing) return;
    try {
      const liveDoc = clone(editor.getJSON() as Node);
      if (!patchImageSrcsInDoc(liveDoc, srcMap, altMap)) return;
      const sel = editor.selection as any;
      applyingInternal = true;
      editor.setContent(liveDoc);
      if (typeof sel?.from === "number" && typeof sel?.to === "number") {
        try { editor.run(setTextSelection(sel.from, sel.to)); } catch {}
      }
    } catch {
      // Keep editor interactive even if an image patch race occurs.
    } finally {
      applyingInternal = false;
    }
  };

  const hydrateImagesProgressive = (doc: Node, noteId: string, ticket: number, forceOriginal = false) => {
    const imgs = collectVaultImages(doc);
    if (!imgs.length || !props.vault) {
      imageStates.set([]);
      return;
    }
    const dedup = new Map<string, string>();
    for (const img of imgs) dedup.set(img.attachmentId, img.name);
    const entries = [...dedup.entries()];
    if (!forceOriginal) {
      imageStates.set(entries.map(([attachmentId, name]) => ({ attachmentId, name, status: "loading" })));
    }
    void Promise.allSettled(
      entries.map(async ([attachmentId, name]) => {
        if (forceOriginal) {
          const dataUrl = await Attachments.readImage(props.vault!, noteId, attachmentId);
          return { attachmentId, name, dataUrl, lod: "l3" as const };
        }
        const res = await readImageThumbnail(noteId, attachmentId);
        return { attachmentId, name, dataUrl: res.dataUrl, lod: res.lod };
      }),
    ).then((results) => {
      if (!alive || ticket !== generation) return;
      const srcMap = new Map<string, string>();
      const altMap = new Map<string, string>();
      const nextStates: ImageLoadItem[] = [];
      results.forEach((r, i) => {
        const [attachmentId, name] = entries[i];
        if (r.status === "fulfilled") {
          srcMap.set(attachmentId, r.value.dataUrl);
          altMap.set(attachmentId, name);
          nextStates.push({ attachmentId, name, status: r.value.lod });
        } else {
          altMap.set(attachmentId, `${name}（加载失败）`);
          nextStates.push({ attachmentId, name, status: "failed", error: assetErrorText(r.reason) });
        }
      });
      imageStates.set(nextStates);
      if (srcMap.size > 0 || altMap.size > 0) {
        applyImagePatches(ticket, srcMap, altMap);
      }
      if (forceOriginal) upgradingOrig.set(false);
    });
  };

  const mountNote = (item: Note) => {
    clearSaveTimer();
    clearMeasureTimers();
    stop?.(); stopSel?.();
    const old = session(); old?.setEditable(false); session.set(null); old?.dispose();
    measuredLines.set([]); selectionHead.set(null); imageStates.set([]); pendingExternal.set(null);
    owner = item.id; generation++; initialized = false; localDirty = false; blocked.set(false); error.set(""); dismiss();
    if (item.noteFormat === "rich-v1" && !item.noteDocument) return;
    initialized = true;
    origin = { id: item.id, note: item.note, noteFormat: item.noteFormat, noteOriginal: item.noteOriginal };
    const ticket = generation;
    try {
      const doc: Node = item.noteFormat === "rich-v1" ? clone(item.noteDocument!) : JSON.parse(NoteMarkdown.fromMarkdown(item.note ?? "")).noteDocument;
      const placeholderView = makePlaceholderViewDoc(doc);
      // Frame-1 immediate mount: toolbar & editable cursor appear without waiting for image I/O.
      const editor = createNoteSession(doc, placeholderView);
      anchorCount.set(Math.max(1, extractLineAnchors(doc).length));
      last = storedDocument(editor.getJSON() as Node);
      selectionHead.set(typeof (editor.selection as any)?.head === "number" ? (editor.selection as any).head : null);
      session.set(editor);
      stop = editor.on("revision", () => {
        if (!alive || ticket !== generation || applyingInternal) return;
        localDirty = true;
        revision.update(n => n + 1);
        scheduleSave(300);
        scheduleMeasure(60);
      });
      stopSel = editor.on("selectionUpdate", () => {
        if (!alive || ticket !== generation) return;
        const head = (editor.selection as any)?.head;
        selectionHead.set(typeof head === "number" ? head : null);
        if (anchorCount() > 250) scheduleMeasure(80);
      });
      // Load L2 400px thumbnails concurrently in the background without blocking editing.
      hydrateImagesProgressive(doc, item.id, ticket, false);
    } catch (e) {
      blocked.set(true);
      error.set(String(e));
    }
  };

  effect(() => {
    const item = props.item;
    if (owner !== item.id) {
      if (owner) save();
      mountNote(item);
      return;
    }
    const externalUpdate =
      initialized &&
      owner === item.id &&
      item.noteFormat === "rich-v1" &&
      !!item.noteDocument &&
      !!last &&
      !equivalent(last, item.noteDocument);
    if (externalUpdate) {
      // Never tear down active typing or undo history: defer to non-blocking LiveSyncBanner.
      if (localDirty || session()?.isFocused) {
        pendingExternal.set(item);
      } else {
        mountNote(item);
      }
      return;
    }
    if (!initialized && !(item.noteFormat === "rich-v1" && !item.noteDocument)) {
      mountNote(item);
    }
  });
  effect(() => { if (!props.editable) save(); session()?.setEditable(!!props.editable && !blocked()); });
  effect(() => {
    const ed = session();
    const on = showLineNumbers();
    textScale();
    if (!ed || !on) {
      clearMeasureTimers();
      measuredLines.set([]);
      return;
    }
    scheduleMeasure(0);
  });
  function save() {
    clearSaveTimer();
    const editor = session();
    if (!editor || !alive || blocked() || editor.composing) return;
    try {
      const doc = storedDocument(editor.getJSON() as Node);
      if (last && equivalent(last, doc)) { localDirty = false; return; }
      last = doc; localDirty = false; props.onChange(patchFor(origin, doc), owner); error.set("");
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
      if (image) {
        try {
          const thumb = await readImageThumbnail(owner, meta.id);
          atom.attrs!.src = thumb.dataUrl;
          atom.attrs!.alt = meta.name;
        } catch {
          atom.attrs!.src = "";
          atom.attrs!.alt = meta.name;
        }
      }
      if (!alive || ticket !== generation || !writable()) return;
      session()!.insertContent(atom); save(); bumpNoteAssets(); file.set(""); dismiss();
    } catch (e) { if (alive && ticket === generation) error.set(assetErrorText(e)); }
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
        <View style={{ flexDirection: "row", alignItems: "center", backgroundColor: c().field, borderRadius: 6, padding: 2, gap: 1 }}>
          <Tool label="正文" glyph="正文" compactText disabled={!writable()} onPress={() => run(command("setParagraph"))} />
          <Tool label="标题 1" glyph="H1" compactText disabled={!writable()} onPress={() => run(command("toggleHeading", { level: 1 }))} />
          <Tool label="标题 2" glyph="H2" compactText disabled={!writable()} onPress={() => run(command("toggleHeading", { level: 2 }))} />
          <Tool label="标题 3" glyph="H3" compactText disabled={!writable()} onPress={() => run(command("toggleHeading", { level: 3 }))} />
        </View>
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
        <Divider />
        <Tool testID="note-line-numbers-toggle" label={showLineNumbers() ? "隐藏行号" : "显示行号"} icon="lineNumbers" glyph="行号" compactText selected={showLineNumbers()} onPress={toggleLineNumbers} />
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
    <If when={!!pendingExternal()}>
      <View testID="live-sync-banner" style={{ flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 12, paddingVertical: 8, borderRadius: 8, borderWidth: 1, borderColor: c().blueLine, backgroundColor: c().blueSoft, marginBottom: 10 }}>
        <Icon name="sync" size={14} tint={c().blue} />
        <T size={12} color={c().blue} style={{ flex: 1 }}>收到外部同步或 AI 更新，当前编辑焦点与撤销栈已保留。</T>
        <If when={!!props.onOpenHistory}>
          <Btn label="对照历史" kind="ghost" onPress={() => props.onOpenHistory?.()} />
        </If>
        <Btn label="应用最新内容" kind="primary" onPress={() => { const ext = pendingExternal(); if (ext) mountNote(ext); }} />
        <Btn label="稍后" kind="ghost" onPress={() => pendingExternal.set(null)} />
      </View>
    </If>
    <If when={imageStates().some((s) => s.status === "l2" || s.status === "failed")}>
      <View testID="image-lod-bar" style={{ flexDirection: "row", alignItems: "center", flexWrap: "wrap", gap: 8, paddingHorizontal: 10, paddingVertical: 6, borderRadius: 8, borderWidth: 1, borderColor: c().line, backgroundColor: c().soft2, marginBottom: 10 }}>
        <If when={imageStates().some((s) => s.status === "l2")}>
          <Pill tone="blue">≈ 预览图 · L2 400px</Pill>
          <Btn
            testID="load-original-images-btn"
            label={upgradingOrig() ? "加载原图中…" : "加载原图 · 100%"}
            kind="ghost"
            disabled={upgradingOrig()}
            onPress={() => {
              const ed = session();
              if (!ed || upgradingOrig()) return;
              upgradingOrig.set(true);
              hydrateImagesProgressive(storedDocument(ed.getJSON() as Node), owner, generation, true);
            }}
          />
        </If>
        <Each of={imageStates().filter((s) => s.status === "failed")} key={(s) => s.attachmentId}>
          {(img) => (
            <Row gap={6}>
              <T size={11.5} color={c().red}>图片「{img().name}」未就绪（{img().error || "加载失败"}）</T>
              <Btn
                label="重试"
                kind="ghost"
                onPress={() => {
                  const ed = session();
                  if (!ed) return;
                  hydrateImagesProgressive(storedDocument(ed.getJSON() as Node), owner, generation, false);
                }}
              />
              <Btn
                label="拉取云端"
                kind="ghost"
                onPress={() => void requestRemoteAsset(owner, { id: img().attachmentId, noteId: owner, name: img().name, mime: "image/png", size: 0, state: "remote" })}
              />
            </Row>
          )}
        </Each>
      </View>
    </If>
    <If when={!!error()}><T color={c().red}>{error()}</T></If>
    <If when={!!session()} else={<TextView document={props.item.noteDocument ? project(props.item.noteDocument) : project(documentFor({ id: props.item.id, note: props.item.note, noteFormat: "plain" }))} links="report" onLinkPress={() => {}} />}>
      <Each of={session() ? [session()!] : []} key={editor => editor}>{editor => <RichEditor editor={editor()} editable={!!props.editable && !blocked()} testID="note-rich-editor" accessibilityLabel="笔记正文" onChange={() => scheduleSave(300)} onBlur={save}
        onSelectionChange={({ selection }) => selectionHead.set(selection.head)}
        onContentSizeChange={() => measureNow(false)}
        onLayout={() => scheduleMeasure(16)}
        contentLayer={
          <View style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, pointerEvents: "none" }}>
            <If when={showLineNumbers()}>
              <View
                testID="note-line-gutter"
                style={{
                  position: "absolute",
                  top: 0,
                  left: 0,
                  bottom: 0,
                  width: metrics().hairlineX + 1,
                  pointerEvents: "none",
                }}
              >
                <View
                  style={{
                    position: "absolute",
                    top: 6,
                    bottom: 6,
                    left: metrics().hairlineX,
                    width: 1,
                    backgroundColor: c().line,
                  }}
                />
                <Each of={measuredLines()} key={(row) => row.line}>
                  {(row) => (
                    <View
                      testID={`note-line-num-${row().line}`}
                      style={{
                        position: "absolute",
                        left: 0,
                        top: row().top,
                        width: metrics().numberWidth,
                        height: row().height,
                        justifyContent: "center",
                        alignItems: "flex-end",
                      }}
                    >
                      <T
                        mono
                        size={11.5}
                        weight={activeLine() === row().line ? "600" : "400"}
                        color={activeLine() === row().line ? c().ink2 : c().faint}
                      >
                        {String(row().line)}
                      </T>
                    </View>
                  )}
                </Each>
              </View>
            </If>
          </View>
        }
        style={{ height: 520 }}
        styles={{
          content: {
            fontSize: fs(14.5),
            lineHeight: fs(25),
            color: c().ink,
            paddingVertical: 8,
            paddingLeft: showLineNumbers() ? metrics().contentPaddingLeft : 2,
            paddingRight: 2,
          },
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
function Divider() { return <View style={{ width: 1, height: 14, backgroundColor: c().line, marginHorizontal: 3 }} />; }
function Tool(props: { testID?: string; label: string; glyph?: string; icon?: IconName; onPress: () => void; disabled?: boolean; selected?: boolean; compactText?: boolean; bold?: boolean; italic?: boolean; underline?: boolean; strike?: boolean }) {
  return <View testID={props.testID} role="button" accessibilityLabel={props.label} tooltip={props.label} accessibilityState={{ disabled: !!props.disabled, selected: !!props.selected }} onPress={props.disabled ? undefined : props.onPress}
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
