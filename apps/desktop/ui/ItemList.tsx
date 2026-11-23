import { shortcutLabel } from "./shortcut-label";
// The middle column: heading, new item, search, filters and virtualized rows.
import { effect, type JSX, List, signal, View } from "nsh";
import { Menu, type MenuItem } from "nsh/desktop";
import { Icon } from "./icons";
import { Btn, copySecret, Empty, IconBtn, T } from "./kit";
import {
  audit, chip, createItem, DEST_NAME, dest, edit, meshConflicts, noteCategories, noteCategory, prefetchNoteNeighbors, query, restore, selected, select,
  toggleFavorite, togglePin, TYPE_NAME, visible, type Item, type ItemType,
} from "./store";
import { askDeleteForever, askEmptyTrash, askTrash } from "./sheets";
import { c, layout, MONO, fs } from "./theme";
import { secondsLeft, TotpText } from "./totp";
import { deviceSubtitle, deviceTitle, importDeviceDocuments, newDevice } from "./devices";
import { RowCode } from "./entries/linkedCode";
import { askAddCode } from "./entries/CodeDetail";
import { listDensity, rowPadding, sidebarCollapsed, SORT_LABEL, setSortMode, sortMode, toggleSidebar, type SortMode } from "./preferences";
import { isMac } from "./native";
import { catLeaf, isAiActor } from "./notes/knowledge";
import { isRelayOffline } from "./relay";

export const searchFocus = signal(0);
const itemTitle = (item: Item) => (item.type === "device" ? deviceTitle(item) : item.title || "未命名");

const COLORS = ["#24292f", "#3265db", "#a259ff", "#c8102e", "#2f8f63", "#f38020", "#555b66", "#0f7b8a"];
export function Tile(props: { item: Item; size?: number }) {
  const s = () => props.size ?? 34;
  const icon = () =>
    ({ totp: "clock", secureNote: "note", creditCard: "wallet", identity: "id", crypto: "coin", device: "server" } as const)[props.item.type as Exclude<ItemType, "password">] ?? "key";
  const ch = () => (props.item.title || "?").trim().charAt(0).toUpperCase() || "?";
  const color = () => COLORS[ch().charCodeAt(0) % COLORS.length];
  return (
    <If
      when={props.item.type === "password"}
      else={
        <View style={{ width: s(), height: s(), borderRadius: s() * 0.24, borderWidth: 1, borderColor: c().line, backgroundColor: c().surface, alignItems: "center", justifyContent: "center" }}>
          <Icon name={icon()} size={s() * 0.5} tint="#617795" />
        </View>
      }
    >
      <View style={{ width: s(), height: s(), borderRadius: s() * 0.24, backgroundColor: color(), alignItems: "center", justifyContent: "center" }}>
        <T size={s() * 0.42} weight="600" color="#ffffff">{ch()}</T>
      </View>
    </If>
  );
}

function subtitle(item: Item): string {
  switch (item.type) {
    case "password": return item.username || item.url || "";
    case "totp": return item.username || item.issuer || "";
    case "creditCard": return [item.card?.brand, item.card?.number ? `•••• ${String(item.card.number).slice(-4)}` : ""].filter(Boolean).join(" · ");
    case "identity": return [item.identity?.lastName, item.identity?.firstName].filter(Boolean).join("") || item.identity?.email || "";
    case "crypto": return [item.network, item.address ? `${String(item.address).slice(0, 6)}…${String(item.address).slice(-4)}` : ""].filter(Boolean).join(" · ");
    case "secureNote": return String(item.note ?? "").replace(/\s+/g, " ").slice(0, 120);
    case "device": return deviceSubtitle(item);
  }
}

function shortDate(iso?: string) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const today = new Date();
  if (d.toDateString() === today.toDateString()) return `今天 ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  return d.getFullYear() === today.getFullYear() ? `${d.getMonth() + 1}月${d.getDate()}日` : d.toISOString().slice(0, 10);
}

/** Moves a note to another category; the note itself is unchanged. */
export function moveToCategoryMenu(item: Item): MenuItem[] {
  const move = (cat: string) => { if ((item.category ?? "") !== cat) edit(item.id, (d) => (d.category = cat)); };
  return [
    { label: "未分类", checked: !item.category, onSelect: () => move("") },
    { type: "separator" },
    ...noteCategories().map((cat): MenuItem => ({ label: cat, checked: item.category === cat, onSelect: () => move(cat) })),
  ];
}

export function rowMenu(item: Item): MenuItem[] {
  if (item.isDeleted) {
    return [
      { label: `恢复「${itemTitle(item)}」`, onSelect: () => void restore(item) },
      { type: "separator" },
      { label: "永久删除…", onSelect: () => askDeleteForever(item) },
    ];
  }
  return [
    { label: "打开", onSelect: () => select(item.id) },
    ...(item.type === "password"
      ? ([
          { label: "复制用户名", shortcut: "mod+c", onSelect: () => copySecret(item.username, "用户名") },
          { label: "复制密码", shortcut: "mod+shift+c", onSelect: () => copySecret(item.password, "密码") },
        ] as MenuItem[])
      : []),
    ...(item.type === "secureNote" ? ([{ label: "移动到分类", submenu: moveToCategoryMenu(item) }] as MenuItem[]) : []),
    { type: "separator" },
    { label: item.isFavorite ? "取消收藏" : "收藏", shortcut: "mod+d", onSelect: () => toggleFavorite(item) },
    { label: item.isPinned ? "取消置顶" : "置顶", onSelect: () => togglePin(item) },
    { type: "separator" },
    { label: "移到回收站…", shortcut: "mod+backspace", onSelect: () => askTrash(item) },
  ];
}

function ItemRow(props: { item: Item; active?: boolean }) {
  const item = () => props.item;
  const on = () => selected()?.id === item().id;
  const flagged = () => !!audit()[item().id];
  const hasConflict = () => !!meshConflicts()[item().id];
  const liveTick = () => props.active !== false;
  return (
    <View
      role="button"
      testID={`row-${item().id}`}
      accessibilityLabel={itemTitle(item())}
      accessibilityState={{ selected: on() }}
      onPress={() => select(item().id)}
      onContextMenu={(e) => void Menu.popup(rowMenu(item()), e.pagePosition)}
      style={{
        flexDirection: "row", gap: 11, paddingHorizontal: 10, paddingVertical: rowPadding(listDensity()), borderRadius: 9, borderWidth: 1, marginVertical: 1,
        borderColor: on() ? c().blueLine : "transparent", backgroundColor: on() ? c().blueSoft : "transparent",
        alignItems: item().type === "secureNote" ? "flex-start" : "center", cursor: "pointer",
      }}
      hoverStyle={on() ? undefined : { backgroundColor: c().soft }}
    >
      <If when={item().type !== "secureNote"}><Tile item={item()} /></If>
      <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 5 }}>
          <T size={13} weight="600" lines={item().type === "device" ? 2 : 1} style={{ flexShrink: 1 }}>{itemTitle(item())}</T>
          <If when={item().isFavorite}><Icon name="star" size={11} tint="#e3a008" fill /></If>
          <If when={item().isPinned}><Icon name="pin" size={11} tint={c().faint} /></If>
          {/* Design v1.21.0: compact key badge when the entry holds passkeys (metadata only). */}
          <If when={dest() !== "trash" && (item().passkeys?.length ?? 0) > 0}>
            <View testID={`passkey-badge-${item().id}`} accessibilityLabel={`已保存 ${item().passkeys!.length} 个通行密钥`}
              tooltip={`已保存 ${item().passkeys!.length} 个通行密钥`}
              style={{ flexShrink: 0, width: 18, height: 16, borderRadius: 5, alignItems: "center", justifyContent: "center", backgroundColor: on() ? c().surface : c().blueSoft }}>
              <Icon name="passkey" size={11} tint={c().blue} />
            </View>
          </If>
        </View>
        <T size={11.5} color={c().muted} lines={item().type === "secureNote" ? 2 : 1}>
          {dest() === "trash" ? `${TYPE_NAME[item().type]} · 删除于 ${shortDate(item().deletedAt)}` : subtitle(item()) || " "}
        </T>
        <If when={item().type === "secureNote" && dest() !== "trash"}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 5, marginTop: 4 }}>
            <Icon name="folder" size={11} tint={c().faint} />
            <T size={11} color={c().faint} style={{ flex: 1 }} lines={1}>{catLeaf(item().category)}</T>
            <If when={hasConflict()}>
              <View style={{ backgroundColor: c().orangeSoft, borderRadius: 4, paddingHorizontal: 5, paddingVertical: 1 }}>
                <T size={9.5} weight="600" color={c().orange}>并行分支</T>
              </View>
            </If>
            <If when={isAiActor(item().lastActor)}>
              <View style={{ backgroundColor: c().blueSoft, borderRadius: 4, paddingHorizontal: 5, paddingVertical: 1 }}>
                <T size={9.5} weight="600" color={c().blue}>AI</T>
              </View>
            </If>
            <T size={11} color={c().faint}>{shortDate(item().updatedAt)}</T>
          </View>
        </If>
      </View>
      <If when={item().type === "password"}><RowCode item={item()} active={liveTick()} /></If>
      <If when={item().type === "totp" && dest() !== "trash"}>
        <View style={{ alignItems: "flex-end", gap: 3 }}>
          <TotpText secret={item().secret} period={item().period ?? 30} active={liveTick()} style={{ fontFamily: MONO, fontSize: fs(12), fontWeight: "600", color: c().blue }} />
          <T size={11} color={c().faint}>{liveTick() ? `${secondsLeft(item().period ?? 30)}s` : "—"}</T>
        </View>
      </If>
      <If when={flagged() && dest() !== "trash"}>
        <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: c().orange }} accessibilityLabel="需关注" />
      </If>
    </View>
  );
}

const NEW_LABEL: Partial<Record<string, string>> = { devices: "新增设备", notes: "新建笔记", accounts: "新建账号", codes: "添加验证码", wallets: "新建", all: "新建", favorites: "新建" };

export function newItemMenu(): MenuItem[] {
  const d = dest();
  if (d === "wallets") {
    return [
      { label: "银行卡", onSelect: () => void createItem("creditCard") },
      { label: "身份信息", onSelect: () => void createItem("identity") },
      { label: "加密货币钱包", onSelect: () => void createItem("crypto") },
    ];
  }
  return [
    { label: "账号", shortcut: "mod+n", onSelect: () => void createItem("password") },
    { label: "验证码", onSelect: () => askAddCode() },
    { label: "笔记", shortcut: "mod+shift+n", onSelect: () => void createItem("secureNote") },
    { type: "separator" },
    { label: "银行卡", onSelect: () => void createItem("creditCard") },
    { label: "身份信息", onSelect: () => void createItem("identity") },
    { label: "加密货币钱包", onSelect: () => void createItem("crypto") },
    { type: "separator" },
    { label: "设备与服务", onSelect: () => void newDevice() },
  ];
}

/** Destinations whose header button opens a menu rather than creating directly. */
const MENU_DESTS = ["wallets", "all", "favorites", "devices"];
export function newInCurrent(position?: { x: number; y: number }, fromButton = false) {
  if (dest() === "devices") {
    if (!fromButton) return void newDevice();
    return void Menu.popup([
      { label: "新增设备", shortcut: "mod+n", onSelect: () => void newDevice() },
      { label: "导入设备资料…", onSelect: () => void importDeviceDocuments() },
    ], position);
  }
  if (dest() === "codes") return askAddCode();
  const direct: Partial<Record<string, ItemType>> = { notes: "secureNote", accounts: "password", codes: "totp" };
  const t = direct[dest()];
  if (t) void createItem(t);
  else void Menu.popup(newItemMenu(), position);
}

function Chip(props: { value: ReturnType<typeof chip>; label: string }) {
  const on = () => chip() === props.value;
  return (
    <View role="button" accessibilityState={{ selected: on() }} onPress={() => chip.set(props.value)}
      style={{ paddingHorizontal: 7, paddingVertical: 4, borderRadius: 6, backgroundColor: on() ? c().blueSoft : "transparent", cursor: "pointer" }}
      hoverStyle={on() ? undefined : { backgroundColor: c().field }}>
      <T size={11.5} color={on() ? c().blue : c().muted} lines={1}>{props.label}</T>
    </View>
  );
}

function Chips() {
  const d = dest();
  const conflictCount = () => Object.keys(meshConflicts()).length;
  if (d === "trash") return <T size={11.5} color={c().muted}>项目保留至手动永久删除</T>;
  if (d === "wallets") return <><Chip value="all" label="全部" /><Chip value="card" label="银行卡" /><Chip value="identity" label="身份" /><Chip value="crypto" label="加密钱包" /></>;
  if (d === "accounts") return <><Chip value="all" label="全部" /><Chip value="fav" label="收藏" /><Chip value="issue" label="需关注" /></>;
  if (d === "notes") return (
    <>
      <Chip value="all" label="全部" />
      <Chip value="fav" label="收藏" />
      <Chip value="ai" label="AI 更新" />
      <If when={conflictCount() > 0}><Chip value="conflict" label={`并行分支 ${conflictCount()}`} /></If>
    </>
  );
  return <><Chip value="all" label="全部" /><Chip value="fav" label="收藏" /></>;
}

export function ItemList() {
  const title = () => (dest() === "notes" ? (noteCategory() ? catLeaf(noteCategory()) : "全部笔记") : DEST_NAME[dest()]);
  const viewableIds = signal<Set<string>>(new Set());
  let input: any;
  effect(() => {
    if (searchFocus() > 0) input?.focus?.();
  });
  effect(() => {
    // Reset viewability mask when switching lists so initial rows tick immediately.
    dest(); noteCategory(); chip(); query();
    viewableIds.set(new Set());
  });
  let header: { x: number; y: number } | undefined;
  return (
    <View testID="item-list" style={{ width: layout.list, backgroundColor: c().list, borderRightWidth: 1, borderRightColor: c().line }}>
      <View desktop={{ windowDrag: true }} style={{ paddingTop: 44, paddingHorizontal: 16, paddingBottom: 10 }}>
        <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", marginBottom: 14, gap: 8 }}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 6, flexShrink: 1, minWidth: 0 }}>
            <If when={sidebarCollapsed()}>
              <View desktop={{ windowDrag: false }}>
                <IconBtn testID="sidebar-expand-btn" icon="sidebar" label={isMac ? "显示边栏 (⌃⌘S)" : "显示边栏 (Ctrl+Alt+S)"} size={15} onPress={toggleSidebar} />
              </View>
            </If>
            <T size={20} weight="600" lines={dest() === "devices" ? undefined : 1} style={{ flexShrink: 1 }}>{title()}</T>
          </View>
          <View desktop={{ windowDrag: false }} onLayout={(e) => (header = { x: e.bounds.origin.x, y: e.bounds.origin.y + 34 })}>
            <If when={dest() === "trash"} else={<Btn testID="new-item" label={`${NEW_LABEL[dest()] ?? "新建"}${MENU_DESTS.includes(dest()) ? " ▾" : ""}`} icon="plus" kind="primary" onPress={() => newInCurrent(header, true)} />}>
              <Btn label="清空" disabled={visible().length === 0} onPress={askEmptyTrash} />
            </If>
          </View>
        </View>
        <View desktop={{ windowDrag: false }} tooltip="搜索当前列表；多个关键词用空格分隔。在「全部项目」中可跨类型搜索。" style={{ flexDirection: "row", alignItems: "center", gap: 6, backgroundColor: c().field, borderRadius: 7, paddingHorizontal: 9 }}>
          <Icon name="search" size={13} tint={c().faint} />
          <SearchInput ref={(r: any) => (input = r)} />
          <If when={query()} else={<T size={11} color={c().faint} style={{ flexShrink: 0 }}>{shortcutLabel("⌘K")}</T>}>
            <IconBtn icon="x" label="清除搜索" size={13} onPress={() => { query.set(""); input?.focus?.(); }} />
          </If>
        </View>
        <View desktop={{ windowDrag: false }} style={{ flexDirection: "row", alignItems: "center", gap: 3, marginTop: 10, minHeight: 24, flexWrap: "wrap" }}>
          {/* Rebuilt per destination: a component body runs only once. */}
          <Each of={[dest()]} key={(d) => d}>{() => <Chips />}</Each>
          <View style={{ flex: 1, minWidth: 4 }} />
          <T size={11} color={c().faint} lines={1}>{visible().length} {query().trim() ? "个搜索结果" : "个项目"}</T>
          <View role="button" testID="sort-menu" accessibilityLabel={`排序：${SORT_LABEL[sortMode()]}`} tooltip="排序方式（置顶项目始终在前）"
            onPress={(e: any) => void Menu.popup((Object.keys(SORT_LABEL) as SortMode[]).map((m) => ({ label: SORT_LABEL[m], checked: sortMode() === m, onSelect: () => setSortMode(m) })), e?.pagePosition)}
            style={{ flexDirection: "row", alignItems: "center", gap: 2, paddingHorizontal: 5, paddingVertical: 4, borderRadius: 6, cursor: "pointer" }}
            hoverStyle={{ backgroundColor: c().field }}>
            <T size={11} color={c().muted} lines={1}>{SORT_LABEL[sortMode()]}</T>
            <Icon name="chevd" size={10} tint={c().faint} />
          </View>
        </View>
        <If when={isRelayOffline()}>
          <View testID="offline-local-first-strip" style={{ flexDirection: "row", alignItems: "center", gap: 6, marginTop: 8, paddingHorizontal: 9, paddingVertical: 5, borderRadius: 7, backgroundColor: c().soft2, borderWidth: 1, borderColor: c().line2 }}>
            <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: c().orange }} />
            <T size={11} color={c().muted} lines={1} style={{ flex: 1 }}>离线可用 · 本地完整读写，联网后自动双向同步</T>
          </View>
        </If>
      </View>
      <List<Item>
        each={visible()}
        keyExtractor={(i) => i.id}
        empty={<ListEmpty />}
        style={{ flex: 1, minHeight: 220 }}
        contentStyle={{ paddingHorizontal: 8, paddingBottom: 10 }}
        onViewableItemsChange={({ viewableItems }) => {
          const next = new Set<string>();
          for (const v of viewableItems) {
            if (v.isViewable && v.item?.id) next.add(v.item.id);
          }
          viewableIds.set(next);
          const firstNote = viewableItems.find((v) => v.isViewable && v.item?.type === "secureNote");
          if (firstNote?.item?.id) prefetchNoteNeighbors(firstNote.item.id, 2);
        }}
      >
        {(item) => <ItemRow item={item()} active={viewableIds().size === 0 || viewableIds().has(item().id)} />}
      </List>
    </View>
  );
}

import { Input } from "nsh/base";
const SEARCH_PLACEHOLDER: Partial<Record<string, string>> = {
  notes: "搜索笔记、标签或目录…",
  accounts: "搜索账号、网站或用户名…",
  codes: "搜索发行方或账号…",
  wallets: "搜索银行卡、证件或地址…",
  devices: "搜索设备、主机或脚本…",
  trash: "搜索已删除的项目…",
};

function SearchInput(props: { ref: (r: any) => void }) {
  const onKey = (e: { key: string }) => {
    if (e.key === "Escape") {
      if (query()) query.set("");
      return;
    }
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    const list = visible();
    if (!list.length) return;
    const curId = selected()?.id;
    const idx = list.findIndex((i) => i.id === curId);
    const delta = e.key === "ArrowDown" ? 1 : -1;
    const nextIdx = idx < 0 ? 0 : Math.max(0, Math.min(list.length - 1, idx + delta));
    if (list[nextIdx] && list[nextIdx].id !== curId) select(list[nextIdx].id);
  };
  return (
    <Input
      ref={props.ref}
      testID="search"
      value={query()}
      placeholder={SEARCH_PLACEHOLDER[dest()] ?? "搜索名称、账号、备注…"}
      accessibilityLabel={`搜索${DEST_NAME[dest()]}，多个关键词用空格分隔`}
      autoCorrect={false}
      onKeyPress={onKey}
      onChange={({ value }) => query.set(value)}
      style={{ flex: 1, minWidth: 0, fontSize: fs(12.5), paddingVertical: 6, color: c().ink, backgroundColor: "transparent", borderWidth: 0 }}
    />
  );
}

function ListEmpty(): JSX.Element {
  if (query()) {
    return <Empty icon="search" title="没有匹配的项目" text="试试更少的关键词，或在「全部项目」中搜索。" action={<Btn label="清除搜索" onPress={() => query.set("")} />} />;
  }
  if (dest() === "trash") return <Empty icon="trash" title="回收站是空的" text="删除的项目会出现在这里，可随时恢复。" />;
  return (
    <Empty icon={dest() === "notes" ? "note" : "plus"} title={noteCategory() ? `「${noteCategory()}」中还没有笔记` : "这里还没有项目"} text="新建一个开始使用。"
      action={<Btn label={NEW_LABEL[dest()] ?? "新建"} kind="primary" onPress={() => newInCurrent()} />} />
  );
}
