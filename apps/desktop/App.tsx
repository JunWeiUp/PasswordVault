// PasswordVault for Mac — Native Shell preview. The UI follows
// docs/design/macos-app; Mac vault commands run in the headless Rust owner.
import { effect, keymap, mount, platform, signal, View } from "nsh";
import { Menu, Tray, Window } from "nsh/desktop";
import { Detail } from "./ui/Detail";
import { ItemList, newInCurrent, searchFocus } from "./ui/ItemList";
import { closeSheet, SheetHost, sheetOpen, T, copySecret } from "./ui/kit";
import { LockScreen, OnboardingScreen } from "./ui/Lock";
import { openQuickAccess, QuickAccessHost } from "./ui/QuickAccess";
import { openSettings, SettingsHost } from "./ui/Settings";
import { Sidebar } from "./ui/Sidebar";
import { askTrash } from "./ui/sheets";
import {
  boot, call, flush, toast, createItem, dest, load, editing, go, items, lock, onLock, phase, query, selected, selection, settings, toastText, toggleFavorite,
  type Dest,
} from "./ui/store";
import { c, TEXT_SCALES, textScale } from "./ui/theme";
import { Storage } from "nsh";
import { Generator, Health } from "./ui/Tools";
import { exportBackup } from "./ui/backup";
import { desktopCapabilities, isMac, onLockSignals, setCaptureProtection } from "./ui/native";
import { startShortcut } from "./ui/hotkey";
import { quickAccessOpen } from "./ui/QuickAccess";
import { connectBrowser } from "./ui/browser";
import { pollEvery } from "./ui/polling";
import { WindowCtl } from "passwordvault/native";
import { AiApprovalHost, AiWorkspacePage } from "./ui/ai";
import { codeFor, copyAccountCode } from "./ui/entries/linkedCode";
import { hideFromCapture, loadPreferences, trayIcon } from "./ui/preferences";

// NSH 0.5 replaced the static window API with WindowRef; `Window.get` is reactive,
// so this applies once the main window exists.
effect(() => {
  Window.get("main")?.set({ title: "PasswordVault", titleBar: { style: isMac ? "hidden" : "default", height: 40 } });
});

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
        { label: "退出 PasswordVault", shortcut: "mod+q", onSelect: () => void quitApplication() },
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
        { label: "复制验证码", shortcut: "mod+alt+c", disabled: !on || !selected() || !codeFor(selected()!), onSelect: () => selected() && void copyAccountCode(selected()!) },
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
        { label: "AI 访问", shortcut: "mod+alt+a", disabled: !on, onSelect: () => go("ai") },
        { type: "separator" },
        { label: selected()?.isFavorite ? "取消收藏" : "收藏", shortcut: "mod+d", disabled: !on || !selected() || !!selected()?.isDeleted, onSelect: () => selected() && toggleFavorite(selected()!) },
        { label: "移到回收站…", shortcut: "mod+backspace", disabled: !on || !selected() || !!selected()?.isDeleted, onSelect: () => selected() && askTrash(selected()!) },
        { type: "separator" },
        { label: "锁定", shortcut: "mod+l", disabled: !on, onSelect: () => void lock() },
      ],
    },
    { label: "窗口", submenu: [{ role: "minimize" }, { role: "zoom" }, { type: "separator" }, { label: isMac ? "关闭窗口" : "最小化窗口", shortcut: "mod+w", onSelect: () => isMac ? WindowCtl.hide() : Window.get("main")?.minimize() }] },
  ]);
});

keymap.bind("escape", () => sheetOpen() && closeSheet());

// Automatic locking: system sleep, screen lock/screensaver, session switch and
// system-wide idle time come from Rust (ui/native.ts). One subscription for the
// app's lifetime drains the native queue, also while locked, so stale signals
// never lock a freshly unlocked vault.
// The Mac service owns locking while its interface is absent.
if (!isMac) {
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
}
async function quitApplication() {
  if (!(await flush())) return;
  try { await WindowCtl.quit(); } catch { toast("退出未完成，请重试。"); }
}
onLock(() => closeSheet());
void loadPreferences();
effect(() => {
  const on = hideFromCapture();
  if (desktopCapabilities.captureProtection) setCaptureProtection(on);
});
// Menu bar / notification-area icon. Its menu never shows vault content.
effect(() => {
  if (!trayIcon()) { Tray.set(null); return; }
  const on = unlocked();
  const show = () => { if (!windowShown()) WindowCtl.show(); Window.get("main")?.focus(); };
  Tray.set({
    tooltip: "PasswordVault",
    menu: [
      { label: "打开 PasswordVault", onSelect: show },
      { label: "快速访问", disabled: !on, onSelect: () => { show(); if (!quickAccessOpen()) openQuickAccess(); } },
      { label: "锁定", disabled: !on, onSelect: () => void lock() },
      { type: "separator" },
      { label: "退出 PasswordVault", onSelect: () => void quitApplication() },
    ],
  });
});
void Storage.getItem("textScale").then((v) => {
  const n = Number(v);
  if (TEXT_SCALES.some(([s]) => s === n)) textScale.set(n);
});
void startShortcut(() => {
  if (!windowShown()) WindowCtl.show();
  if (unlocked() && !quickAccessOpen()) openQuickAccess();
});

function Workspace() {
  const tool = () => dest() === "generator" || dest() === "health" || dest() === "ai";
  return (
    <View style={{ flex: 1, flexDirection: "row" }}>
      <Sidebar />
      <If when={tool()} else={<><ItemList /><Detail /></>}>
        <If when={dest() === "generator"}><Generator /></If>
        <If when={dest() === "health"}><Health /></If>
        <If when={dest() === "ai"}><AiWorkspacePage /></If>
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

// Save while the component tree is still mounted, then exit this UI process.
// Dock reopening reconnects to the background owner.
const windowShown = signal(true);
let closingWindow = false;
{
  WindowCtl.install();
  setInterval(() => {
    if (isMac && WindowCtl.quitRequested() && !closingWindow) { void quitApplication(); return; }
    const shown = WindowCtl.visible();
    if (shown === windowShown()) return;
    if (!shown && isMac && !closingWindow) {
      closingWindow = true;
      void (async () => {
        if (!(await flush())) {
          closingWindow = false;
          WindowCtl.show();
          toast("保存失败，窗口已保留，请重试。");
          return;
        }
        WindowCtl.finishClose();
      })().catch(() => { closingWindow = false; WindowCtl.show(); toast("关闭未完成，请重试。"); });
    }
  }, 500);
}
pollEvery(1000, async (isActive) => {
  const requestedPhase = phase();
  if (requestedPhase !== "locked" && requestedPhase !== "unlocked") return;
  const status = await call<{ unlocked: boolean }>({ op: "status" });
  if (!isActive() || phase() !== requestedPhase) return;
  if (status.unlocked && requestedPhase === "locked") await load();
  else if (!status.unlocked && requestedPhase === "unlocked") await lock();
});

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
