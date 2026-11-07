// PasswordVault for Mac — Native Shell preview. The UI follows
// docs/design/macos-app; vault-core runs in this app's Rust crate.
import { effect, keymap, mount, platform, signal, View } from "nsh";
import { Menu, Window } from "nsh/desktop";
import { Detail } from "./ui/Detail";
import { ItemList, newInCurrent, searchFocus } from "./ui/ItemList";
import { closeSheet, SheetHost, sheetOpen, T, copySecret } from "./ui/kit";
import { LockScreen, OnboardingScreen } from "./ui/Lock";
import { openQuickAccess, QuickAccessHost } from "./ui/QuickAccess";
import { openSettings, SettingsHost } from "./ui/Settings";
import { Sidebar } from "./ui/Sidebar";
import { askTrash } from "./ui/sheets";
import {
  boot, call, createItem, dest, load, editing, go, items, lock, onLock, phase, releaseForHiddenWindow, query, selected, selection, settings, toastText, toggleFavorite,
  type Dest,
} from "./ui/store";
import { c, TEXT_SCALES, textScale } from "./ui/theme";
import { Storage } from "nsh";
import { Generator, Health } from "./ui/Tools";
import { exportBackup } from "./ui/backup";
import { isMac, onLockSignals } from "./ui/native";
import { startShortcut } from "./ui/hotkey";
import { quickAccessOpen } from "./ui/QuickAccess";
import { connectBrowser } from "./ui/browser";
import { WindowCtl } from "passwordvault/native";
import { AiApprovalHost } from "./ui/ai";

Window.setTitle("PasswordVault");
Window.setTitleBar({ style: isMac ? "hidden" : "default", height: 40 });

const unlocked = () => phase() === "unlocked";
const DESTS: Dest[] = ["all", "accounts", "codes", "wallets", "notes", "devices"];

effect(() => {
  const on = unlocked();
  Menu.setApplicationMenu([
    platform.os === "macos" && {
      label: "PasswordVault",
      submenu: [
        { role: "about" },
        { type: "separator" },
        { label: "设置…", shortcut: "mod+,", disabled: !on, onSelect: () => openSettings() },
        { type: "separator" },
        { role: "hide" },
        { role: "hideOthers" },
        { role: "showAll" },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    {
      label: "文件",
      submenu: [
        { label: "新建", shortcut: "mod+n", disabled: !on, onSelect: () => newInCurrent() },
        { label: "新建笔记", shortcut: "mod+shift+n", disabled: !on, onSelect: () => void createItem("secureNote") },
        { type: "separator" },
        { label: "导出加密备份…", shortcut: "mod+shift+e", disabled: !on, onSelect: exportBackup },
      ],
    },
    {
      label: "编辑",
      submenu: [
        { role: "undo" }, { role: "redo" }, { type: "separator" },
        { role: "cut" }, { role: "copy" }, { role: "paste" }, { role: "selectAll" },
        { type: "separator" },
        { label: "复制密码", shortcut: "mod+shift+c", disabled: !on || selected()?.type !== "password", onSelect: () => selected() && copySecret(selected()!.password, "密码") },
        { label: "查找", shortcut: "mod+k", disabled: !on, onSelect: () => searchFocus.update((n) => n + 1) },
      ],
    },
    {
      label: "显示",
      submenu: [
        ...DESTS.map((d, i) => ({ label: ["全部项目", "账号", "验证码", "钱包", "笔记", "设备与服务"][i], shortcut: `mod+${i + 1}`, disabled: !on, checked: on && dest() === d, onSelect: () => go(d) })),
        { type: "separator" },
        { label: "个人收藏", disabled: !on, onSelect: () => go("favorites") },
        { label: "回收站", disabled: !on, onSelect: () => go("trash") },
        { type: "separator" },
        { label: editing() ? "完成编辑" : "编辑", shortcut: "mod+e", disabled: !on || !selected(), onSelect: () => editing.update((e) => !e) },
        { type: "separator" },
        { role: "toggleFullScreen" },
      ],
    },
    {
      label: "密码库",
      submenu: [
        { label: "快速访问", shortcut: "mod+shift+space", disabled: !on, onSelect: openQuickAccess },
        { label: "密码生成器", shortcut: "mod+alt+g", disabled: !on, onSelect: () => go("generator") },
        { label: "密码健康", shortcut: "mod+alt+h", disabled: !on, onSelect: () => go("health") },
        { type: "separator" },
        { label: selected()?.isFavorite ? "取消收藏" : "收藏", shortcut: "mod+d", disabled: !on || !selected() || !!selected()?.isDeleted, onSelect: () => selected() && toggleFavorite(selected()!) },
        { label: "移到回收站…", shortcut: "mod+backspace", disabled: !on || !selected() || !!selected()?.isDeleted, onSelect: () => selected() && askTrash(selected()!) },
        { type: "separator" },
        { label: "锁定", shortcut: "mod+l", disabled: !on, onSelect: () => void lock() },
      ],
    },
    { label: "窗口", submenu: [{ role: "minimize" }, { role: "zoom" }, { type: "separator" }, { label: isMac ? "关闭窗口" : "最小化窗口", shortcut: "mod+w", onSelect: () => isMac ? WindowCtl.hide() : Window.minimize() }] },
  ]);
});

keymap.bind("escape", () => sheetOpen() && closeSheet());

// Automatic locking: system sleep, screen lock/screensaver, session switch and
// system-wide idle time come from Rust (ui/native.ts). One subscription for the
// app's lifetime drains the native queue, also while locked, so stale signals
// never lock a freshly unlocked vault.
const SLEEP = 1, SESSION = 2, SCREEN = 4, SCREENSAVER = 8;
let fallbackSince = performance.now();
let unlockedSince = performance.now();
// A successful unlock is activity even when accessibility/automation input did
// not reset the OS idle counter. Background item refreshes never reset this clock.
effect(() => {
  if (phase() === "unlocked") unlockedSince = performance.now();
});
effect(() => {
  dest(); selection(); query(); items(); editing();
  fallbackSince = performance.now();
});
onLockSignals(({ events, idleSeconds }) => {
  if (!unlocked()) return;
  const s = settings();
  const onSleep = (events & SLEEP) !== 0 && s.macLockOnSleep !== false;
  const onScreen = (events & (SESSION | SCREEN | SCREENSAVER)) !== 0 && s.macLockOnScreenLock !== false;
  if (onSleep || onScreen) return void lock();
  if (s.macNeverIdleLock) return;
  const limit = Math.min(Math.max(Number(s.autoLockMinutes ?? 60), 1), 120) * 60;
  const sinceUnlock = Math.max(0, (performance.now() - unlockedSince) / 1000);
  const idle = Math.min(idleSeconds ?? (performance.now() - fallbackSince) / 1000, sinceUnlock);
  if (idle >= limit) void lock();
});
onLock(() => closeSheet());
void Storage.getItem("textScale").then((v) => {
  const n = Number(v);
  if (TEXT_SCALES.some(([s]) => s === n)) textScale.set(n);
});
void startShortcut(() => {
  if (!windowShown()) WindowCtl.show();
  if (unlocked() && !quickAccessOpen()) openQuickAccess();
});

function Workspace() {
  const tool = () => dest() === "generator" || dest() === "health";
  return (
    <View style={{ flex: 1, flexDirection: "row" }}>
      <Sidebar />
      <If when={tool()} else={<><ItemList /><Detail /></>}>
        <If when={dest() === "generator"} else={<Health />}><Generator /></If>
      </If>
    </View>
  );
}

function Toast() {
  return (
    <If when={toastText()}>
      <View style={{ pointerEvents: "none", position: "absolute", bottom: 34, left: 0, right: 0, alignItems: "center" }}>
        <View style={{ backgroundColor: "#26354b", borderRadius: 10, paddingHorizontal: 18, paddingVertical: 10 }}>
          <T size={12.5} color="#ffffff">{toastText()}</T>
        </View>
      </View>
    </If>
  );
}

// The browser host can unlock the core on a cold start (explicit setting);
// pick that up so the interface follows the core.
let browserStarted = false;

// Closing the window keeps the app running (Dock reopens it) with its interface
// unmounted and decrypted items dropped. Test hosts keep the default (see window_ctl.rs).
const windowShown = signal(true);
let releasedForHidden = false;
{
  WindowCtl.install();
  setInterval(() => {
    const shown = WindowCtl.visible();
    if (shown === windowShown()) return;
    windowShown.set(shown);
    if (!shown) {
      closeSheet();
      if (unlocked()) {
        releasedForHidden = true;
        void releaseForHiddenWindow();
      }
    } else if (releasedForHidden) {
      releasedForHidden = false;
      void call<{ unlocked: boolean }>({ op: "status" }).then((s) => (s.unlocked ? load() : phase.set("locked")));
    }
  }, 500);
}
setInterval(() => {
  if (phase() !== "locked") return;
  void call<{ unlocked: boolean }>({ op: "status" }).then((s) => {
    if (s.unlocked && phase() === "locked") void load();
  }).catch(() => {});
}, 1000);

function App() {
  void boot().then(() => {
    if (!browserStarted) {
      browserStarted = true;
      connectBrowser();
    }
  });
  return (
    <View style={{ flex: 1, backgroundColor: c().surface }}>
      <If when={windowShown()}>
      <If when={phase() === "unlocked"} else={
        <If when={phase() === "onboard"} else={<If when={phase() === "locked"} else={<View style={{ flex: 1, backgroundColor: c().soft2 }} />}><LockScreen /></If>}>
          <OnboardingScreen />
        </If>
      }>
        <Workspace />
        <SettingsHost />
        <QuickAccessHost />
      </If>
      <SheetHost />
      <AiApprovalHost />
      <Toast />
      </If>
    </View>
  );
}

mount(App);
