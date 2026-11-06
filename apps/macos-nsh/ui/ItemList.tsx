// The middle column: heading, new item, search, filters and rows.
import { effect, type JSX, signal, View, Scroll } from "nsh";
import { Menu, type MenuItem } from "nsh/desktop";
import { Icon } from "./icons";
import { Btn, copySecret, Empty, IconBtn, T } from "./kit";
import {
  audit, chip, createItem, DEST_NAME, dest, edit, noteCategories, noteCategory, query, restore, selected, select,
  toggleFavorite, togglePin, TYPE_NAME, visible, type Item, type ItemType,
} from "./store";
import { askDeleteForever, askEmptyTrash, askTrash } from "./sheets";
import { c, layout, MONO, fs } from "./theme";
import { secondsLeft, TotpText } from "./totp";
import { deviceSubtitle, importDeviceDocuments, newDevice } from "./devices";
import { askAddCode } from "./entries/CodeDetail";

export const searchFocus = signal(0);

const COLORS = ["#24292f", "#3265db", "#a259ff", "#c8102e", "#2f8f63", "#f38020", "#555b66", "#0f7b8a"];
export function Tile(props: { item: Item; size?: number }) {
  const s = () => props.size ?? 34;
  const icon = () =>
    ({ totp: "clock", secureNote: "note", creditCard: "wallet", identity: "id", crypto: "coin", device: "server" } as const)[props.item.type as Exclude<ItemType, "password">];
  if (props.item.type === "password") {
    const ch = (props.item.title || "?").trim().charAt(0).toUpperCase() || "?";
    const color = COLORS[ch.charCodeAt(0) % COLORS.length];
    return (
      <View style={{ width: s(), height: s(), borderRadius: s() * 0.24, backgroundColor: color, alignItems: "center", justifyContent: "center" }}>
        <T size={s() * 0.42} weight="600" color="#ffffff">{ch}</T>
      </View>
    );
  }
  return (
    <View style={{ width: s(), height: s(), borderRadius: s() * 0.24, borderWidth: 1, borderColor: c().line, backgroundColor: c().surface, alignItems: "center", justifyContent: "center" }}>
      <Icon name={icon()} size={s() * 0.5} tint="#617795" />
    </View>
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
      { label: `恢复「${item.title || "未命名"}」`, onSelect: () => void restore(item) },
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

function ItemRow(props: { item: Item }) {
  const item = () => props.item;
  const on = () => selected()?.id === item().id;
  const flagged = () => !!audit()[item().id];
  return (
    <View
      role="button"
      testID={`row-${item().id}`}
      accessibilityLabel={item().title}
      accessibilityState={{ selected: on() }}
      onPress={() => select(item().id)}
      onContextMenu={(e) => void Menu.popup(rowMenu(item()), e.pagePosition)}
      style={{
        flexDirection: "row", gap: 11, padding: 10, borderRadius: 9, borderWidth: 1, marginVertical: 1,
        borderColor: on() ? c().blueLine : "transparent", backgroundColor: on() ? c().blueSoft : "transparent",
        alignItems: item().type === "secureNote" ? "flex-start" : "center", cursor: "pointer",
      }}
      hoverStyle={on() ? undefined : { backgroundColor: c().soft }}
    >
      <If when={item().type !== "secureNote"}><Tile item={item()} /></If>
      <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 5 }}>
          <T size={13} weight="600" lines={item().type === "device" ? undefined : 1} style={{ flexShrink: 1 }}>{item().title || "未命名"}</T>
          <If when={item().isFavorite}><Icon name="star" size={11} tint="#e3a008" fill /></If>
          <If when={item().isPinned}><Icon name="pin" size={11} tint={c().faint} /></If>
        </View>
        <T size={11.5} color={c().muted} lines={item().type === "secureNote" ? 2 : 1}>
          {dest() === "trash" ? `${TYPE_NAME[item().type]} · 删除于 ${shortDate(item().deletedAt)}` : subtitle(item()) || " "}
        </T>
        <If when={item().type === "secureNote" && dest() !== "trash"}>
          <View style={{ flexDirection: "row", alignItems: "center", gap: 5, marginTop: 4 }}>
            <Icon name="folder" size={11} tint={c().faint} />
            <T size={11} color={c().faint} style={{ flex: 1 }}>{item().category || "未分类"}</T>
            <T size={11} color={c().faint}>{shortDate(item().updatedAt)}</T>
          </View>
        </If>
      </View>
      <If when={item().type === "totp" && dest() !== "trash"}>
        <View style={{ alignItems: "flex-end", gap: 3 }}>
          <TotpText secret={item().secret} period={item().period ?? 30} style={{ fontFamily: MONO, fontSize: fs(12), fontWeight: "600", color: c().blue }} />
          <T size={11} color={c().faint}>{secondsLeft(item().period ?? 30)}s</T>
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

export function newInCurrent(position?: { x: number; y: number }) {
  if (dest() === "devices") return void newDevice();
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
      style={{ paddingHorizontal: 9, paddingVertical: 4, borderRadius: 6, backgroundColor: on() ? c().blueSoft : "transparent", cursor: "pointer" }}
      hoverStyle={on() ? undefined : { backgroundColor: c().field }}>
      <T size={12} color={on() ? c().blue : c().muted}>{props.label}</T>
    </View>
  );
}

function Chips() {
  const d = dest();
  if (d === "trash") return <T size={11.5} color={c().muted}>项目保留至手动永久删除</T>;
  if (d === "wallets") return <><Chip value="all" label="全部" /><Chip value="card" label="银行卡" /><Chip value="identity" label="身份" /><Chip value="crypto" label="加密钱包" /></>;
  if (d === "accounts") return <><Chip value="all" label="全部" /><Chip value="fav" label="收藏" /><Chip value="issue" label="需关注" /></>;
  return <><Chip value="all" label="全部" /><Chip value="fav" label="收藏" /></>;
}

export function ItemList() {
  const title = () => (dest() === "notes" ? noteCategory() ?? "全部笔记" : DEST_NAME[dest()]);
  let input: any;
  effect(() => {
    if (searchFocus() > 0) input?.focus?.();
  });
  let header: { x: number; y: number } | undefined;
  return (
    <View testID="item-list" style={{ width: layout.list, backgroundColor: c().list, borderRightWidth: 1, borderRightColor: c().line }}>
      <View desktop={{ windowDrag: true }} style={{ paddingTop: 44, paddingHorizontal: 16, paddingBottom: 10 }}>
        <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", marginBottom: 14, gap: 8 }}>
          <T size={20} weight="600" lines={dest() === "devices" ? undefined : 1} style={{ flexShrink: 1 }}>{title()}</T>
          <View desktop={{ windowDrag: false }} onLayout={(e) => (header = { x: e.bounds.origin.x, y: e.bounds.origin.y + 34 })}>
            <If when={dest() === "trash"} else={<Btn testID="new-item" label={NEW_LABEL[dest()] ?? "新建"} icon="plus" kind="primary" onPress={() => newInCurrent(header)} />}>
              <Btn label="清空" disabled={visible().length === 0} onPress={askEmptyTrash} />
            </If>
          </View>
        </View>
        <If when={dest() === "devices"}><View desktop={{ windowDrag: false }} style={{ marginBottom: 10 }}><Btn label="导入设备资料…" testID="import-device-documents" onPress={() => void importDeviceDocuments()} /></View></If>
        <View desktop={{ windowDrag: false }} style={{ flexDirection: "row", alignItems: "center", gap: 6, backgroundColor: c().field, borderRadius: 7, paddingHorizontal: 9 }}>
          <Icon name="search" size={13} tint={c().faint} />
          <SearchInput ref={(r: any) => (input = r)} />
          <T size={11} color={c().faint}>⌘K</T>
        </View>
        <View desktop={{ windowDrag: false }} style={{ flexDirection: "row", alignItems: "center", gap: 4, marginTop: 10, minHeight: 24 }}>
          {/* Rebuilt per destination: a component body runs only once. */}
          <Each of={[dest()]} key={(d) => d}>{() => <Chips />}</Each>
        </View>
      </View>
      <Scroll style={{ flex: 1 }} contentStyle={{ paddingHorizontal: 8, paddingBottom: 10 }}>
        <If when={visible().length} else={<ListEmpty />}>
          <Each of={visible()} key={(i) => i.id}>{(item) => <ItemRow item={item()} />}</Each>
        </If>
      </Scroll>
      <View style={{ flexDirection: "row", justifyContent: "space-between", alignItems: "center", paddingHorizontal: 16, paddingVertical: 9, borderTopWidth: 1, borderTopColor: c().line }}>
        <T size={11} color={c().faint}>{visible().length} 个项目</T>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 4 }}>
          <Icon name="lock" size={11} tint={c().faint} />
          <T size={11} color={c().faint}>已加密</T>
        </View>
      </View>
    </View>
  );
}

import { Input } from "nsh/base";
function SearchInput(props: { ref: (r: any) => void }) {
  return (
    <Input
      ref={props.ref}
      testID="search"
      value={query()}
      placeholder={dest() === "notes" ? "搜索笔记" : "搜索标题、用户名、网站或标签"}
      accessibilityLabel="搜索"
      autoCorrect={false}
      onChange={({ value }) => query.set(value)}
      style={{ flex: 1, fontSize: fs(12.5), paddingVertical: 6, color: c().ink, backgroundColor: "transparent", borderWidth: 0 }}
    />
  );
}

function ListEmpty(): JSX.Element {
  if (query()) {
    return <Empty icon="search" title="没有匹配的项目" text="试试其他关键词，或清除搜索。" action={<Btn label="清除搜索" onPress={() => query.set("")} />} />;
  }
  if (dest() === "trash") return <Empty icon="trash" title="回收站是空的" text="删除的项目会出现在这里，可随时恢复。" />;
  return (
    <Empty icon={dest() === "notes" ? "note" : "plus"} title={noteCategory() ? `「${noteCategory()}」中还没有笔记` : "这里还没有项目"} text="新建一个开始使用。"
      action={<Btn label={NEW_LABEL[dest()] ?? "新建"} kind="primary" onPress={() => newInCurrent()} />} />
  );
}
