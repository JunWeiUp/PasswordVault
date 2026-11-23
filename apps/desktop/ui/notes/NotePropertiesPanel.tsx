// Structured properties, directory/slug routing, and Agent auto-save banner for secure notes.
import { effect, signal, View } from "nsh";
import { Input } from "nsh/base";
import { Menu } from "nsh/desktop";
import { Icon } from "../icons";
import { Btn, copySecret, IconBtn, Pill, Row, SmallAction, T } from "../kit";
import { aiSettings } from "../ai";
import { desktopCapabilities } from "../native";
import { moveToCategoryMenu } from "../ItemList";
import { edit, go, type Item } from "../store";
import { c, fs, MONO } from "../theme";
import { catLeaf, isAiActor, isAiWritableCategory, type NoteProperty } from "./knowledge";

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

const hasCustomProps = (item: Item) =>
  Array.isArray(item.noteProperties) && item.noteProperties.length > 0;

export function NotePropertiesPanel(props: { item: Item; editable: boolean }) {
  const item = () => props.item;
  // Auto-collapse when a note has no custom properties so the note body starts near the top.
  const open = signal(hasCustomProps(props.item));
  const adding = signal(false);
  const newKey = signal("");
  const newVal = signal("");
  const slugDraft = signal(props.item.slug ?? "");
  const slugFocused = signal(false);
  let lastId = props.item.id;

  effect(() => {
    const cur = item();
    if (cur.id !== lastId) {
      lastId = cur.id;
      open.set(hasCustomProps(cur));
      slugDraft.set(cur.slug ?? "");
      adding.set(false);
      newKey.set("");
      newVal.set("");
    } else if ((cur.slug ?? "") !== slugDraft() && !slugFocused()) {
      slugDraft.set(cur.slug ?? "");
    }
  });

  const propsList = (): NoteProperty[] =>
    Array.isArray(item().noteProperties) ? item().noteProperties : [];
  const tagsCount = () => (Array.isArray(item().tags) ? item().tags.length : 0);
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
        marginBottom: 12,
        overflow: "hidden",
      }}
    >
      <View
        testID="note-properties-toggle"
        role="button"
        accessibilityLabel="展开或收起属性与路由"
        onPress={() => open.update((v) => !v)}
        style={{
          flexDirection: "row",
          alignItems: "center",
          gap: 8,
          paddingHorizontal: 12,
          paddingVertical: 7,
          cursor: "pointer",
        }}
        hoverStyle={{ backgroundColor: c().soft }}
      >
        <Icon name={open() ? "chevd" : "chev"} size={12} tint={c().faint} />
        <T size={11.5} weight="600" color={c().ink2}>属性与路由</T>
        <If when={!open() && item().category}>
          <T size={11} color={c().muted}>{catLeaf(item().category)}</T>
        </If>
        <If when={item().slug}>
          <T mono size={11} color={c().muted}>/{item().slug}</T>
        </If>
        <If when={!open() && tagsCount() > 0}>
          <T size={11} color={c().faint}>{tagsCount()} 标签</T>
        </If>
        <If when={propsList().length > 0}>
          <T size={11} color={c().faint}>{propsList().length} 项属性</T>
        </If>
        <View style={{ flex: 1 }} />
        <If when={desktopCapabilities.ai}>
          <Pill tone={writable() ? "info" : "neutral"}>
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
