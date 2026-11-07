import { isMac, desktopCapabilities } from "./native";
// The left column: destinations, note categories, tools, sync status, settings and lock.
import { Scroll, Text, View } from "nsh";
import { titleBar } from "nsh/desktop";
import { Icon, type IconName } from "./icons";
import { IconBtn, T } from "./kit";
import {
  audit, countIn, dest, go, items, lock, noteCategories, noteCategory, query, type Dest,
} from "./store";
import { c, fs, layout } from "./theme";
import { askCategory, askRemoveCategory } from "./sheets";
import { openQuickAccess } from "./QuickAccess";
import { openSettings } from "./Settings";
import { appVersion } from "./version";
import { SHORTCUT_LABEL, shortcut } from "./hotkey";
import { syncStatus } from "./relay";

export function Logo(props: { size?: number }) {
  const s = () => props.size ?? 32;
  return (
    <View style={{ width: s(), height: s(), borderRadius: s() * 0.25, backgroundColor: "#1d2b48", alignItems: "center", justifyContent: "center" }}>
      <Text style={{ color: "#ffffff", fontWeight: "700", fontSize: s() * 0.48 }}>P</Text>
    </View>
  );
}

function NavRow(props: { testID?: string; icon: IconName; label: string; active: boolean; count?: number | string; countTone?: string; onPress: () => void; indent?: boolean; hint?: string; onContextMenu?: (e: any) => void }) {
  return (
    <View
      role="button"
      testID={props.testID}
      accessibilityLabel={props.label}
      accessibilityState={{ selected: props.active }}
      onPress={props.onPress}
      onContextMenu={props.onContextMenu}
      style={{
        flexDirection: "row", alignItems: "center", gap: 10, height: fs(props.indent ? 28 : 32),
        paddingLeft: props.indent ? 36 : 10, paddingRight: 10, borderRadius: 7, marginBottom: 1,
        backgroundColor: props.active ? c().blueLine : "transparent", cursor: "pointer",
      }}
      hoverStyle={props.active ? undefined : { backgroundColor: c().field }}
    >
      <Icon name={props.icon} size={props.indent ? 13 : 16} tint={props.active ? c().blue : c().ink2} />
      <T size={props.indent ? 12.5 : 13} weight={props.active ? "600" : "400"} color={props.active ? c().blue : c().ink2} style={{ flex: 1 }} lines={1}>{props.label}</T>
      {props.hint && <T size={10.5} color={c().faint}>{props.hint}</T>}
      {props.count !== undefined && props.count !== 0 && <T size={11.5} color={props.countTone ?? (props.active ? c().blue : c().faint)}>{String(props.count)}</T>}
    </View>
  );
}

const MAIN: [Dest, string, IconName][] = [
  ["all", "全部项目", "grid"],
  ["accounts", "账号", "key"],
  ["codes", "验证码", "clock"],
  ["wallets", "钱包", "wallet"],
  ["notes", "笔记", "note"],
  ["devices", "设备与服务", "server"],
];

function Label(props: { text: string; right?: any }) {
  return (
    <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginTop: 14, marginBottom: 4, paddingHorizontal: 10, minHeight: 20 }}>
      <T size={11} color={c().faint}>{props.text}</T>
      {props.right}
    </View>
  );
}

export function Sidebar() {
  const issues = () => Object.keys(audit()).length;
  const notesCount = (cat: string) => items().filter((i) => i.type === "secureNote" && !i.isDeleted && i.category === cat).length;
  return (
    <View testID="sidebar" style={{ width: layout.sidebar, backgroundColor: c().side, borderRightWidth: 1, borderRightColor: c().sideLine, paddingHorizontal: 10, paddingBottom: 10 }}>
      <View desktop={{ windowDrag: true }} style={{ height: Math.max(titleBar().height, 40) }} />
      <View style={{ flexDirection: "row", alignItems: "center", gap: 10, marginHorizontal: 8, marginBottom: 12 }}>
        <Logo />
        <View>
          <T size={14} weight="600">PasswordVault</T>
          <T size={10.5} color={c().muted}>{appVersion} · Native Shell 预览</T>
        </View>
      </View>
      {/* Destinations scroll when the window is short; the footer stays pinned. */}
      <Scroll scrollbar={false} style={{ flex: 1, minHeight: 0 }} contentStyle={{ paddingBottom: 8 }}>
        <Label text="密码库" />
        {MAIN.map(([d, label, icon]) => (
          <>
            <NavRow testID={`nav-${d}`} icon={icon} label={label} active={dest() === d && !(d === "notes" && noteCategory())} count={countIn(d)}
              onPress={() => { go(d); noteCategory.set(null); }} />
            <If when={d === "notes" && dest() === "notes"}>
              <View style={{ flexDirection: "row", alignItems: "center", paddingLeft: 36, paddingRight: 4, height: 22 }}>
                <T size={10.5} color={c().faint} style={{ flex: 1 }}>分类</T>
                <IconBtn icon="plus" label="新增分类" size={12} onPress={askCategory} />
                <IconBtn icon="minus" label="删除所选分类，保留笔记" size={12} disabled={!noteCategory()} onPress={() => noteCategory() && askRemoveCategory(noteCategory()!)} />
              </View>
              <Each of={noteCategories()}>
                {(cat) => (
                  <NavRow indent icon="folder" label={cat()} active={noteCategory() === cat()} count={notesCount(cat())}
                    onPress={() => { noteCategory.set(cat()); query.set(""); }}
                    onContextMenu={() => askRemoveCategory(cat())} />
                )}
              </Each>
            </If>
          </>
        ))}
        <Label text="整理" />
        <NavRow icon="star" label="个人收藏" active={dest() === "favorites"} count={countIn("favorites")} onPress={() => go("favorites")} />
        <NavRow icon="trash" label="回收站" active={dest() === "trash"} count={countIn("trash")} onPress={() => go("trash")} />
        <Label text="工具" />
        <NavRow icon="wand" label="密码生成器" active={dest() === "generator"} onPress={() => go("generator")} />
        <NavRow icon="shield" label="密码健康" active={dest() === "health"} count={issues()} countTone={c().orange} onPress={() => go("health")} />
        <NavRow icon="bolt" label="快速访问" active={false} hint={!desktopCapabilities.globalHotkeys || shortcut() === "disabled" ? undefined : SHORTCUT_LABEL[shortcut()]} onPress={openQuickAccess} />
      </Scroll>
      <View style={{ flexShrink: 0, borderTopWidth: 1, borderTopColor: c().sideLine, paddingTop: 8, gap: 1, backgroundColor: c().side }}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 8, paddingHorizontal: 10, height: 26 }}>
          <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: c().faint }} />
          <T size={11.5} color={c().muted} lines={1}>{syncStatus()}</T>
        </View>
        <NavRow icon="gear" label="设置" active={false} hint={isMac ? "⌘," : "Ctrl+,"} onPress={() => openSettings()} />
        <NavRow testID="lock" icon="lock" label="锁定" active={false} hint={isMac ? "⌘L" : "Ctrl+L"} onPress={() => void lock()} />
      </View>
    </View>
  );
}
