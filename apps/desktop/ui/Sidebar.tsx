import { isMac, desktopCapabilities } from "./native";
// The left column: destinations, note categories, tools, sync status, settings and lock.
import { Scroll, signal, Text, View } from "nsh";
import { Menu, type MenuItem, titleBar } from "nsh/desktop";
import { Icon, type IconName } from "./icons";
import { IconBtn, T } from "./kit";
import {
  audit, countIn, dest, go, items, lock, noteCategories, noteCategory, query, type Dest,
} from "./store";
import { c, fs, layout } from "./theme";
import { askCategory, askRemoveCategory, askRenameCategory } from "./sheets";
import { openQuickAccess } from "./QuickAccess";
import { openSettings } from "./Settings";
import { appVersion } from "./version";
import { SHORTCUT_LABEL, shortcut } from "./hotkey";
import { syncStatus, syncTone } from "./relay";
import { aiSettings, aiWritableCategories, setCategoryAiWritable } from "./ai";
import { buildCatTree, catMatches, isAiWritableCategory, type CatNode } from "./notes/knowledge";

export function Logo(props: { size?: number }) {
  const s = () => props.size ?? 32;
  return (
    <View style={{ width: s(), height: s(), borderRadius: s() * 0.25, backgroundColor: "#1d2b48", alignItems: "center", justifyContent: "center" }}>
      <Text style={{ color: "#ffffff", fontWeight: "700", fontSize: s() * 0.48 }}>P</Text>
    </View>
  );
}

function NavRow(props: { testID?: string; icon: IconName; label: string; active: boolean; count?: number | string; countTone?: string; dot?: string; tooltip?: string; onPress: () => void; indent?: boolean; hint?: string; onContextMenu?: (e: any) => void }) {
  return (
    <View
      role="button"
      testID={props.testID}
      accessibilityLabel={props.label}
      accessibilityState={{ selected: props.active }}
      tooltip={props.tooltip}
      onPress={props.onPress}
      onContextMenu={props.onContextMenu}
      style={{
        flexDirection: "row", alignItems: "center", gap: 10, height: fs(props.indent ? 26 : 30),
        paddingLeft: props.indent ? 36 : 10, paddingRight: 10, borderRadius: 7, marginBottom: 1,
        backgroundColor: props.active ? c().blueLine : "transparent", cursor: "pointer",
      }}
      hoverStyle={props.active ? undefined : { backgroundColor: c().field }}
    >
      <Icon name={props.icon} size={props.indent ? 13 : 16} tint={props.active ? c().blue : c().ink2} />
      <T size={props.indent ? 12.5 : 13} weight={props.active ? "600" : "400"} color={props.active ? c().blue : c().ink2} style={{ flex: 1 }} lines={1}>{props.label}</T>
      {props.hint && <T size={10.5} color={c().faint}>{props.hint}</T>}
      {props.dot && <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: props.dot }} />}
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
    <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginTop: 10, marginBottom: 3, paddingHorizontal: 10, minHeight: 18 }}>
      <T size={11} color={c().faint}>{props.text}</T>
      {props.right}
    </View>
  );
}

const catFolded = signal<Record<string, boolean>>({});

function CategoryTreeRow(props: { node: CatNode; count: number }) {
  const node = () => props.node;
  const active = () => noteCategory() === node().path;
  const folded = () => !!catFolded()[node().path];
  const writable = () => desktopCapabilities.ai && isAiWritableCategory(node().path, aiSettings());
  const directWritable = () => aiWritableCategories().includes(node().path);
  const toggleFold = () => catFolded.update((m) => ({ ...m, [node().path]: !m[node().path] }));
  const menu = (): MenuItem[] => [
    { label: "新建子目录…", onSelect: () => askCategory(node().path) },
    ...(desktopCapabilities.ai
      ? ([{
          label: directWritable() ? "关闭 AI 自动保存" : "允许 AI 自动保存",
          onSelect: () => void setCategoryAiWritable(node().path, !directWritable()),
        }] as MenuItem[])
      : []),
    { type: "separator" },
    { label: "重命名…", onSelect: () => askRenameCategory(node().path) },
    { label: "删除分类…", onSelect: () => askRemoveCategory(node().path) },
  ];
  return (
    <View
      role="button"
      testID={`cat-${node().path}`}
      accessibilityLabel={node().leaf}
      accessibilityState={{ selected: active() }}
      tooltip={writable() ? `${node().path} · 允许 AI 免弹窗自动保存` : node().path}
      onPress={() => { noteCategory.set(node().path); query.set(""); }}
      onContextMenu={(e: any) => void Menu.popup(menu(), e?.pagePosition)}
      style={{
        flexDirection: "row", alignItems: "center", gap: 6, height: fs(26),
        paddingLeft: 20 + node().depth * 14, paddingRight: 10, borderRadius: 7, marginBottom: 1,
        backgroundColor: active() ? c().blueLine : "transparent", cursor: "pointer",
      }}
      hoverStyle={active() ? undefined : { backgroundColor: c().field }}
    >
      <If when={node().hasChildren} else={<View style={{ width: 14 }} />}>
        <View
          role="button"
          accessibilityLabel={folded() ? `展开 ${node().leaf}` : `折叠 ${node().leaf}`}
          onPress={(e: any) => { e?.stopPropagation?.(); toggleFold(); }}
          style={{ width: 14, height: 18, alignItems: "center", justifyContent: "center", borderRadius: 4, cursor: "pointer" }}
          hoverStyle={{ backgroundColor: c().line }}
        >
          <Icon name={folded() ? "chev" : "chevd"} size={10} tint={c().faint} />
        </View>
      </If>
      <Icon name="folder" size={13} tint={active() ? c().blue : c().ink2} />
      <T size={12.5} weight={active() ? "600" : "400"} color={active() ? c().blue : c().ink2} style={{ flex: 1 }} lines={1}>{node().leaf}</T>
      <If when={writable()}>
        <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: c().blue }} accessibilityLabel="允许 AI 自动保存" />
      </If>
      <If when={props.count > 0}>
        <T size={11.5} color={active() ? c().blue : c().faint}>{String(props.count)}</T>
      </If>
    </View>
  );
}

export function Sidebar() {
  const issues = () => Object.keys(audit()).length;
  const notesCount = (cat: string) => items().filter((i) => i.type === "secureNote" && !i.isDeleted && catMatches(i.category, cat)).length;
  const treeNodes = () => buildCatTree(noteCategories(), catFolded());
  const aiOn = () => desktopCapabilities.ai && aiSettings().aiAccessEnabled === true;
  const aiClientCount = () => (desktopCapabilities.ai && Array.isArray(aiSettings().aiAccessClients) ? aiSettings().aiAccessClients.length : 0);
  return (
    <View testID="sidebar" style={{ width: layout.sidebar, backgroundColor: c().side, borderRightWidth: 1, borderRightColor: c().sideLine, paddingHorizontal: 10, paddingBottom: 10 }}>
      <View desktop={{ windowDrag: true }} style={{ height: Math.max(titleBar().height, 40) }} />
      <View style={{ flexDirection: "row", alignItems: "center", gap: 10, marginHorizontal: 8, marginBottom: 8 }}>
        <Logo />
        <View>
          <T size={14} weight="600">PasswordVault</T>
          <T size={10.5} color={c().muted}>{appVersion}</T>
        </View>
      </View>
      {/* Pinned above the scrollable vault destinations so AI access stays visible even with long note trees. */}
      <View style={{ flexShrink: 0, paddingBottom: 6, marginBottom: 4, borderBottomWidth: 1, borderBottomColor: c().sideLine }}>
        <NavRow
          testID="nav-ai"
          icon="spark"
          label="AI 访问"
          active={dest() === "ai"}
          dot={aiOn() ? c().green : undefined}
          count={aiClientCount() || undefined}
          tooltip={aiOn() ? `本机 AI 接口已启用 · ${aiClientCount()} 个已配对客户端` : "管理本机 AI 访问权限与已配对客户端"}
          onPress={() => go("ai")}
        />
      </View>
      {/* Destinations scroll when the window is short; the top AI entry and footer stay pinned. */}
      <Scroll scrollbar={false} style={{ flex: 1, minHeight: 0 }} contentStyle={{ paddingBottom: 8 }}>
        <Label text="密码库" />
        {MAIN.map(([d, label, icon]) => (
          <>
            <NavRow testID={`nav-${d}`} icon={icon} label={label} active={dest() === d && !(d === "notes" && noteCategory())} count={countIn(d)}
              onPress={() => { go(d); noteCategory.set(null); }} />
            <If when={d === "notes" && dest() === "notes"}>
              <View style={{ flexDirection: "row", alignItems: "center", paddingLeft: 34, paddingRight: 4, height: 22 }}>
                <T size={10.5} color={c().faint} style={{ flex: 1 }}>目录</T>
                <IconBtn testID="add-category" icon="plus" label="新增分类" size={12} onPress={() => askCategory()} />
                <IconBtn icon="minus" label="删除所选分类，保留笔记" size={12} disabled={!noteCategory()} onPress={() => noteCategory() && askRemoveCategory(noteCategory()!)} />
              </View>
              <Each of={treeNodes()} key={(n) => n.path}>
                {(node) => <CategoryTreeRow node={node()} count={notesCount(node().path)} />}
              </Each>
            </If>
          </>
        ))}
        <Label text="整理" />
        <NavRow icon="star" label="收藏" active={dest() === "favorites"} count={countIn("favorites")} onPress={() => go("favorites")} />
        <NavRow icon="trash" label="回收站" active={dest() === "trash"} count={countIn("trash")} onPress={() => go("trash")} />
        <Label text="工具" />
        <NavRow icon="wand" label="密码生成器" active={dest() === "generator"} onPress={() => go("generator")} />
        {/* A dot, not a large count: the page explains and ranks the issues. */}
        <NavRow icon="shield" label="密码健康" active={dest() === "health"} dot={issues() ? c().orange : undefined} tooltip={issues() ? `${issues()} 个账号需关注` : undefined} onPress={() => go("health")} />
      </Scroll>
      <View style={{ flexShrink: 0, borderTopWidth: 1, borderTopColor: c().sideLine, paddingTop: 8, gap: 1, backgroundColor: c().side }}>
        <View role="button" accessibilityLabel={`同步状态：${syncStatus()}`} tooltip="打开同步设置" onPress={() => openSettings("relay")}
          style={{ flexDirection: "row", alignItems: "center", gap: 8, paddingHorizontal: 10, height: 26, borderRadius: 7, cursor: "pointer" }} hoverStyle={{ backgroundColor: c().field }}>
          <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: ({ ok: c().green, busy: c().orange, warn: c().red, off: c().faint })[syncTone()] }} />
          <T size={11.5} color={c().muted} lines={1}>{syncStatus()}</T>
        </View>
        {/* Opens a floating panel rather than a page, so it lives with the other actions. */}
        <NavRow icon="bolt" label="快速访问" active={false} hint={!desktopCapabilities.globalHotkeys || shortcut() === "disabled" ? undefined : SHORTCUT_LABEL[shortcut()]} onPress={openQuickAccess} />
        <NavRow icon="gear" label="设置" active={false} hint={isMac ? "⌘," : "Ctrl+,"} onPress={() => openSettings()} />
        <NavRow testID="lock" icon="lock" label="锁定" active={false} hint={isMac ? "⌘L" : "Ctrl+L"} onPress={() => void lock()} />
      </View>
    </View>
  );
}
