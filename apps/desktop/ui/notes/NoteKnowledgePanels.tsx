// Obsidian-style knowledge base panels for secureNote detail view:
// structured properties & slug, Agent auto-save banner, canonical Markdown pane, and wikilinks/backlinks.
import { effect, signal, View } from "nsh";
import { Input } from "nsh/base";
import { Menu } from "nsh/desktop";
import { NoteMarkdown } from "passwordvault/native";
import { Icon } from "../icons";
import { Btn, copySecret, IconBtn, Pill, Row, SmallAction, T } from "../kit";
import { aiSettings } from "../ai";
import { desktopCapabilities } from "../native";
import { moveToCategoryMenu } from "../ItemList";
import { createItem, edit, go, items, reveal, toast, type Item } from "../store";
import { c, fs, MONO } from "../theme";
import {
  catLeaf,
  extractWikilinks,
  findNoteBacklinks,
  isAiActor,
  isAiWritableCategory,
  noteToMarkdown,
  type NoteProperty,
} from "./knowledge";

function shortTime(iso?: string) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const today = new Date();
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  if (d.toDateString() === today.toDateString()) return `今天 ${hh}:${mm}`;
  return `${d.getMonth() + 1}月${d.getDate()}日 ${hh}:${mm}`;
}

export function NotePropertiesPanel(props: { item: Item; editable: boolean }) {
  const item = () => props.item;
  const open = signal(true);
  const adding = signal(false);
  const newKey = signal("");
  const newVal = signal("");
  const slugDraft = signal(props.item.slug ?? "");
  let lastId = props.item.id;

  effect(() => {
    const cur = item();
    if (cur.id !== lastId) {
      lastId = cur.id;
      slugDraft.set(cur.slug ?? "");
      adding.set(false);
      newKey.set("");
      newVal.set("");
    } else if ((cur.slug ?? "") !== slugDraft() && !slugFocused()) {
      slugDraft.set(cur.slug ?? "");
    }
  });
  const slugFocused = signal(false);

  const propsList = (): NoteProperty[] =>
    Array.isArray(item().noteProperties) ? item().noteProperties : [];
  const writable = () => desktopCapabilities.ai && isAiWritableCategory(item().category, aiSettings());

  const commitSlug = (raw: string) => {
    const clean = raw.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
    slugDraft.set(clean);
    if ((item().slug ?? "") !== clean) {
      edit(item().id, (d) => {
        if (clean) d.slug = clean;
        else delete d.slug;
      });
    }
  };

  const updatePropValue = (key: string, value: string) => {
    edit(item().id, (d) => {
      const list: NoteProperty[] = Array.isArray(d.noteProperties) ? [...d.noteProperties] : [];
      const idx = list.findIndex((p) => p.key === key);
      if (idx < 0) return;
      list[idx] = { key, value };
      d.noteProperties = list;
    });
  };

  const removeProp = (key: string) => {
    edit(item().id, (d) => {
      const list: NoteProperty[] = Array.isArray(d.noteProperties) ? [...d.noteProperties] : [];
      const next = list.filter((p) => p.key !== key);
      if (next.length > 0) d.noteProperties = next;
      else delete d.noteProperties;
    });
  };

  const submitNewProp = () => {
    const k = newKey().trim();
    const v = newVal().trim();
    if (!k) return;
    edit(item().id, (d) => {
      const list: NoteProperty[] = Array.isArray(d.noteProperties) ? [...d.noteProperties] : [];
      const idx = list.findIndex((p) => p.key === k);
      if (idx >= 0) list[idx] = { key: k, value: v };
      else list.push({ key: k, value: v });
      d.noteProperties = list;
    });
    newKey.set("");
    newVal.set("");
    adding.set(false);
  };

  return (
    <View
      testID="note-properties-panel"
      style={{
        borderWidth: 1,
        borderColor: c().line,
        borderRadius: 10,
        backgroundColor: c().soft2,
        marginBottom: 14,
        overflow: "hidden",
      }}
    >
      <View
        role="button"
        accessibilityLabel="展开或收起属性与路由"
        onPress={() => open.update((v) => !v)}
        style={{
          flexDirection: "row",
          alignItems: "center",
          gap: 8,
          paddingHorizontal: 12,
          paddingVertical: 8,
          cursor: "pointer",
        }}
        hoverStyle={{ backgroundColor: c().soft }}
      >
        <Icon name={open() ? "chevd" : "chev"} size={12} tint={c().faint} />
        <T size={11.5} weight="600" color={c().ink2}>属性与路由</T>
        <If when={item().slug}>
          <T mono size={11} color={c().muted}>/{item().slug}</T>
        </If>
        <If when={propsList().length > 0}>
          <T size={11} color={c().faint}>{propsList().length} 项属性</T>
        </If>
        <View style={{ flex: 1 }} />
        <If when={desktopCapabilities.ai}>
          <Pill tone={writable() ? "blue" : "gray"}>
            {writable() ? "AI 自动保存" : "仅手动编辑"}
          </Pill>
        </If>
      </View>

      <If when={open()}>
        <View style={{ borderTopWidth: 1, borderTopColor: c().line2, paddingHorizontal: 12, paddingVertical: 10, gap: 8 }}>
          {/* Directory + Slug row */}
          <Row gap={12} wrap>
            <Row gap={6} style={{ flex: 1, minWidth: 210 }}>
              <T size={11.5} color={c().muted} style={{ width: 48 }}>目录</T>
              <If when={!item().isDeleted} else={<T size={12} color={c().ink2}>{item().category || "未分类"}</T>}>
                <View
                  role="button"
                  accessibilityLabel="移动到分类"
                  onPress={(e: any) => void Menu.popup(moveToCategoryMenu(item()), e?.pagePosition)}
                  style={{
                    flexDirection: "row", alignItems: "center", gap: 4,
                    paddingHorizontal: 7, paddingVertical: 3, borderRadius: 6,
                    backgroundColor: c().surface, borderWidth: 1, borderColor: c().line, cursor: "pointer",
                  }}
                  hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blueLine }}
                >
                  <Icon name="folder" size={11} tint={c().blue} />
                  <T size={12} color={c().blue}>{item().category || "未分类"}</T>
                  <Icon name="chevd" size={10} tint={c().blue} />
                </View>
              </If>
            </Row>

            <Row gap={6} style={{ flex: 1, minWidth: 230 }}>
              <T size={11.5} color={c().muted} style={{ width: 42 }}>Slug</T>
              <If when={props.editable} else={
                <T mono size={11.5} color={item().slug ? c().ink2 : c().faint} selectable>
                  {item().slug || "未设置"}
                </T>
              }>
                <Input
                  testID="note-slug-input"
                  value={slugDraft()}
                  placeholder="例如 portfolio-holdings"
                  accessibilityLabel="笔记 Slug 标识"
                  autoCorrect={false}
                  onFocus={() => slugFocused.set(true)}
                  onChange={({ value }) => slugDraft.set(value)}
                  onBlur={() => { slugFocused.set(false); commitSlug(slugDraft()); }}
                  onSubmit={() => commitSlug(slugDraft())}
                  style={{
                    flex: 1, fontSize: fs(11.5), fontFamily: MONO, color: c().ink,
                    paddingHorizontal: 7, paddingVertical: 3, borderRadius: 5,
                    borderWidth: 1, borderColor: c().line, backgroundColor: c().surface,
                  }}
                />
              </If>
              <If when={item().slug}>
                <IconBtn icon="copy" label="复制 Slug" size={12} onPress={() => void copySecret(String(item().slug), "Slug")} />
              </If>
            </Row>
          </Row>

          {/* Tags + AI permission link */}
          <Row gap={12} wrap>
            <Row gap={6} style={{ flex: 1, minWidth: 210 }}>
              <T size={11.5} color={c().muted} style={{ width: 48 }}>标签</T>
              <If when={props.editable} else={
                <T size={12} color={(item().tags ?? []).length ? c().ink2 : c().faint}>
                  {(item().tags ?? []).join("、") || "无"}
                </T>
              }>
                <Input
                  value={(item().tags ?? []).join("、")}
                  placeholder="用顿号分隔，如 资产、长线"
                  accessibilityLabel="笔记标签"
                  autoCorrect={false}
                  onChange={({ value }) =>
                    edit(item().id, (d) => {
                      d.tags = value.split(/[、,，]/).map((s) => s.trim()).filter(Boolean);
                    })
                  }
                  style={{
                    flex: 1, fontSize: fs(11.5), color: c().ink,
                    paddingHorizontal: 7, paddingVertical: 3, borderRadius: 5,
                    borderWidth: 1, borderColor: c().line, backgroundColor: c().surface,
                  }}
                />
              </If>
            </Row>

            <If when={desktopCapabilities.ai}>
              <Row gap={6} style={{ flex: 1, minWidth: 230 }}>
                <T size={11.5} color={c().muted} style={{ width: 42 }}>写入</T>
                <T size={11.5} color={writable() ? c().blue : c().muted} style={{ flex: 1 }} lines={1}>
                  {writable() ? "已配对 Agent 可免弹窗自动更新" : "不在 AI 可写目录内"}
                </T>
                <SmallAction label="权限设置" onPress={() => go("ai")} tint={c().blue} />
              </Row>
            </If>
          </Row>

          {/* Custom structured key-value properties */}
          <If when={propsList().length > 0}>
            <View style={{ borderTopWidth: 1, borderTopColor: c().line2, paddingTop: 8, gap: 5 }}>
              <Each of={propsList()} key={(p) => p.key}>
                {(prop) => (
                  <Row gap={8} style={{ minHeight: 24 }}>
                    <T size={11.5} color={c().muted} style={{ width: 112 }} lines={1}>{prop().key}</T>
                    <If when={props.editable} else={
                      <T size={12} color={c().ink} style={{ flex: 1 }} selectable>{prop().value || "—"}</T>
                    }>
                      <Input
                        value={prop().value}
                        accessibilityLabel={`属性 ${prop().key}`}
                        autoCorrect={false}
                        onChange={({ value }) => updatePropValue(prop().key, value)}
                        style={{
                          flex: 1, fontSize: fs(12), color: c().ink,
                          paddingHorizontal: 7, paddingVertical: 3, borderRadius: 5,
                          borderWidth: 1, borderColor: c().line, backgroundColor: c().surface,
                        }}
                      />
                    </If>
                    <If when={props.editable}>
                      <IconBtn icon="x" label={`删除属性 ${prop().key}`} size={11} onPress={() => removeProp(prop().key)} />
                    </If>
                  </Row>
                )}
              </Each>
            </View>
          </If>

          <If when={props.editable}>
            <If when={adding()} else={
              <Row style={{ paddingTop: 2 }}>
                <SmallAction icon="plus" label="添加属性" tint={c().blue} onPress={() => adding.set(true)} />
              </Row>
            }>
              <Row gap={6} style={{ paddingTop: 4 }}>
                <Input
                  testID="note-prop-key"
                  value={newKey()}
                  placeholder="属性名（如 基准币种）"
                  accessibilityLabel="新属性名"
                  autoCorrect={false}
                  autoFocus
                  onChange={({ value }) => newKey.set(value)}
                  style={{
                    width: 140, fontSize: fs(11.5), color: c().ink,
                    paddingHorizontal: 7, paddingVertical: 4, borderRadius: 5,
                    borderWidth: 1, borderColor: c().line, backgroundColor: c().surface,
                  }}
                />
                <Input
                  testID="note-prop-value"
                  value={newVal()}
                  placeholder="属性值（如 USD / CNY）"
                  accessibilityLabel="新属性值"
                  autoCorrect={false}
                  onChange={({ value }) => newVal.set(value)}
                  onSubmit={submitNewProp}
                  style={{
                    flex: 1, fontSize: fs(11.5), color: c().ink,
                    paddingHorizontal: 7, paddingVertical: 4, borderRadius: 5,
                    borderWidth: 1, borderColor: c().line, backgroundColor: c().surface,
                  }}
                />
                <Btn testID="note-prop-add-confirm" label="添加" kind="primary" disabled={!newKey().trim()} onPress={submitNewProp} />
                <IconBtn icon="x" label="取消添加属性" size={12} onPress={() => { adding.set(false); newKey.set(""); newVal.set(""); }} />
              </Row>
            </If>
          </If>
        </View>
      </If>
    </View>
  );
}

export function AgentAutoSaveBanner(props: { item: Item; onOpenHistory: () => void }) {
  const item = () => props.item;
  return (
    <If when={isAiActor(item().lastActor)}>
      <View
        testID="agent-autosave-banner"
        style={{
          flexDirection: "row",
          alignItems: "center",
          gap: 10,
          paddingHorizontal: 12,
          paddingVertical: 9,
          borderRadius: 9,
          borderWidth: 1,
          borderColor: c().blueLine,
          backgroundColor: c().blueSoft,
          marginBottom: 14,
        }}
      >
        <Icon name="spark" size={15} tint={c().blue} />
        <View style={{ flex: 1, minWidth: 0, gap: 1 }}>
          <T size={12} weight="600" color={c().blue} lines={1}>
            {item().lastActor} · {shortTime(item().updatedAt)} 自动保存
          </T>
          <If when={item().lastSummary}>
            <T size={11.5} color={c().ink2} lines={2}>变更摘要：{item().lastSummary}</T>
          </If>
        </View>
        <Btn label="查看变更 Diff" icon="history" onPress={props.onOpenHistory} />
      </View>
    </If>
  );
}

export function NoteMarkdownPane(props: { item: Item; editable: boolean }) {
  const item = () => props.item;
  const draft = signal(noteToMarkdown(props.item));
  const dirty = signal(false);
  const err = signal("");
  let trackedKey = `${props.item.id}:${props.item.updatedAt ?? ""}`;

  effect(() => {
    const cur = item();
    const key = `${cur.id}:${cur.updatedAt ?? ""}`;
    if (key !== trackedKey && !dirty()) {
      trackedKey = key;
      draft.set(noteToMarkdown(cur));
      err.set("");
    }
  });

  const applyMarkdown = () => {
    if (!props.editable || !dirty()) return;
    try {
      const parser = (NoteMarkdown as any).fromMarkdownPreserving;
      const raw =
        typeof parser === "function" && item().noteDocument
          ? parser(draft(), JSON.stringify(item().noteDocument))
          : NoteMarkdown.fromMarkdown(draft());
      const parsed = JSON.parse(raw);
      edit(item().id, (d) => {
        if (d.noteFormat !== "rich-v1" && !d.noteOriginal) {
          d.noteOriginal = { format: d.noteFormat ?? "plain", source: String(d.note ?? "") };
        }
        d.noteFormat = "rich-v1";
        d.noteDocument = parsed.noteDocument;
        d.note = parsed.text;
        d.lastActor = "手动编辑 · 我";
      });
      dirty.set(false);
      err.set("");
      toast("已同步 Markdown 修改");
    } catch (e) {
      err.set(`Markdown 解析失败：${String(e)}`);
    }
  };

  return (
    <View testID="note-markdown-pane" style={{ gap: 10 }}>
      <Row style={{ justifyContent: "space-between", paddingBottom: 6, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
        <T size={11.5} color={c().muted}>规范 Markdown · 与 Agent MCP 读写格式一致</T>
        <Row gap={6}>
          <Btn label="复制 Markdown" icon="copy" onPress={() => void copySecret(draft(), "Markdown")} />
          <If when={props.editable && dirty()}>
            <Btn testID="md-apply-btn" label="应用修改" icon="check" kind="primary" onPress={applyMarkdown} />
          </If>
        </Row>
      </Row>
      <If when={err()}>
        <T size={12} color={c().red}>{err()}</T>
      </If>
      <If when={props.editable} else={
        <View style={{ backgroundColor: c().soft2, borderWidth: 1, borderColor: c().line, borderRadius: 8, padding: 14 }}>
          <T mono size={12.5} selectable color={c().ink}>{draft() || "（空白笔记）"}</T>
        </View>
      }>
        <Input
          testID="note-markdown-input"
          multiline
          value={draft()}
          accessibilityLabel="Markdown 源码"
          autoCorrect={false}
          onChange={({ value }) => { draft.set(value); dirty.set(true); }}
          onBlur={applyMarkdown}
          style={{
            minHeight: 420,
            fontFamily: MONO,
            fontSize: fs(12.5),
            padding: 14,
            borderRadius: 8,
            borderWidth: 1,
            borderColor: c().line,
            backgroundColor: c().soft2,
            color: c().ink,
          }}
        />
      </If>
    </View>
  );
}

export function NoteLinksSection(props: { item: Item }) {
  const item = () => props.item;
  const outgoing = () => extractWikilinks(noteToMarkdown(item()));
  const incoming = () => findNoteBacklinks(item(), items());

  const findTarget = (titleOrSlug: string) =>
    items().find(
      (n) =>
        n.type === "secureNote" &&
        !n.isDeleted &&
        n.id !== item().id &&
        (n.title === titleOrSlug || n.slug === titleOrSlug),
    );

  const openOrCreateLink = (title: string) => {
    const existing = findTarget(title);
    if (existing) {
      reveal(existing);
      return;
    }
    if (item().isDeleted) return;
    void createItem("secureNote", { title, category: item().category ?? "" }).then(() => {
      toast(`已新建双链笔记「${title}」`);
    });
  };

  return (
    <If when={outgoing().length > 0 || incoming().length > 0}>
      <View
        testID="note-links-section"
        style={{
          marginTop: 22,
          paddingTop: 16,
          borderTopWidth: 1,
          borderTopColor: c().line,
          gap: 14,
        }}
      >
        <If when={outgoing().length > 0}>
          <View style={{ gap: 8 }}>
            <Row gap={6}>
              <Icon name="link" size={13} tint={c().muted} />
              <T size={12} weight="600" color={c().ink2}>双链引用（{outgoing().length}）</T>
            </Row>
            <Row gap={6} wrap>
              {outgoing().map((title) => {
                const target = () => findTarget(title);
                return (
                  <View
                    role="button"
                    accessibilityLabel={`打开双链 ${title}`}
                    onPress={() => openOrCreateLink(title)}
                    style={{
                      flexDirection: "row",
                      alignItems: "center",
                      gap: 5,
                      paddingHorizontal: 9,
                      paddingVertical: 4,
                      borderRadius: 6,
                      borderWidth: 1,
                      borderColor: target() ? c().blueLine : c().line,
                      backgroundColor: target() ? c().blueSoft : c().soft2,
                      cursor: "pointer",
                    }}
                    hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blue }}
                  >
                    <T size={12} color={target() ? c().blue : c().muted}>[[{title}]]</T>
                    <If when={!target()}>
                      <T size={10.5} color={c().faint}>新建</T>
                    </If>
                  </View>
                );
              })}
            </Row>
          </View>
        </If>

        <If when={incoming().length > 0}>
          <View style={{ gap: 8 }}>
            <Row gap={6}>
              <Icon name="link" size={13} tint={c().blue} />
              <T size={12} weight="600" color={c().ink2}>反向链接（{incoming().length}）</T>
            </Row>
            <View style={{ gap: 6 }}>
              {incoming().map((ref) => (
                <View
                  role="button"
                  testID={`backlink-${ref.item.id}`}
                  accessibilityLabel={`跳转到 ${ref.item.title}`}
                  onPress={() => reveal(ref.item)}
                  style={{
                    paddingHorizontal: 11,
                    paddingVertical: 8,
                    borderRadius: 8,
                    borderWidth: 1,
                    borderColor: c().line,
                    backgroundColor: c().soft2,
                    gap: 3,
                    cursor: "pointer",
                  }}
                  hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blueLine }}
                >
                  <Row gap={6}>
                    <Icon name="note" size={12} tint={c().blue} />
                    <T size={12.5} weight="600" color={c().blue} style={{ flex: 1 }} lines={1}>
                      {ref.item.title || "未命名笔记"}
                    </T>
                    <T size={11} color={c().faint}>{catLeaf(ref.item.category)}</T>
                  </Row>
                  <If when={ref.snippet}>
                    <T size={11.5} color={c().muted} lines={1}>{ref.snippet}</T>
                  </If>
                </View>
              ))}
            </View>
          </View>
        </If>
      </View>
    </If>
  );
}
