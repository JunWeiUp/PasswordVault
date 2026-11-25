// PasswordVault for Mac — Native Shell preview. The UI follows
// docs/design/macos-app; Mac vault commands run in the headless Rust owner.
import { effect, keymap, mount, platform, View } from "nsh";
import { Application, Menu, Tray, Window, type WindowRef } from "nsh/desktop";
import { Detail } from "./ui/Detail";
import { ItemList, newInCurrent, searchFocus } from "./ui/ItemList";
import { closeSheet, IconBtn, SheetHost, sheetOpen, T, copySecret } from "./ui/kit";
import { LockScreen, OnboardingScreen } from "./ui/Lock";
import { openQuickAccess, QuickAccessHost } from "./ui/QuickAccess";
import { closeSettings, openSettings, SettingsHost, settingsOpen } from "./ui/Settings";
import { Sidebar } from "./ui/Sidebar";
import { askTrash } from "./ui/sheets";
import {
  boot, coreApi, flush, toast, toastAction, dismissToast, createItem, dest, load, editing, go, items, lock, onLock, phase, query, select, selected, selection, settings, toastText, toggleFavorite, visible,
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
import { hideFromCapture, loadPreferences, noteLineNumbers, setNoteLineNumbers, sidebarCollapsed, toggleSidebar, trayIcon } from "./ui/preferences";

// Configure the main window and intercept close presses through NSH 0.7's native
// lifecycle API so drafts always flush before the UI process exits.
let wiredMainWindow: WindowRef | null = null;
effect(() => {
  const win = Window.get("main");
  win?.set({
    title: "PasswordVault",
    titleBar: { style: isMac ? "hidden" : "default", height: 40 },
    closeOnPress: false,
  });
  if (win && win !== wiredMainWindow) {
    wiredMainWindow = win;
    win.on("closePress", () => void closeMainWindow());
  }
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
        { label: sidebarCollapsed() ? "显示边栏" : "隐藏边栏", shortcut: isMac ? "ctrl+mod+s" : "ctrl+alt+s", disabled: !on, onSelect: toggleSidebar },
        { label: "显示笔记行号", checked: noteLineNumbers(), disabled: !on, onSelect: () => setNoteLineNumbers(!noteLineNumbers()) },
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
    { label: "窗口", submenu: [{ role: "minimize" }, { role: "zoom" }, { type: "separator" }, { label: isMac ? "关闭窗口" : "最小化窗口", shortcut: "mod+w", onSelect: () => isMac ? void closeMainWindow() : Window.get("main")?.minimize() }] },
  ]);
});

const canNavigateList = () =>
  unlocked()
  && !sheetOpen()
  && !settingsOpen()
  && !quickAccessOpen()
  && !editing()
  && dest() !== "generator"
  && dest() !== "health"
  && dest() !== "ai";

function stepSelection(delta: 1 | -1) {
  if (!canNavigateList()) return;
  const list = visible();
  if (!list.length) return;
  const curId = selected()?.id;
  const idx = list.findIndex((i) => i.id === curId);
  const nextIdx = idx < 0 ? 0 : Math.max(0, Math.min(list.length - 1, idx + delta));
  if (list[nextIdx] && list[nextIdx].id !== curId) select(list[nextIdx].id);
}

keymap.bind({
  escape: () => {
    if (sheetOpen()) { closeSheet(); return; }
    if (settingsOpen()) { closeSettings(); return; }
    if (editing()) { editing.set(false); return; }
    if (query()) query.set("");
  },
  down: () => stepSelection(1),
  up: () => stepSelection(-1),
  ...(isMac ? { "ctrl+mod+s": () => unlocked() && toggleSidebar() } : { "ctrl+alt+s": () => unlocked() && toggleSidebar() }),
});

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
let closingWindow = false;
function showMainWindow() {
  Window.get("main")?.show();
  Window.get("main")?.focus();
  if (desktopCapabilities.captureProtection) setCaptureProtection(hideFromCapture());
}
async function closeMainWindow() {
  if (closingWindow) return;
  closingWindow = true;
  try {
    if (!(await flush())) {
      closingWindow = false;
      toast("保存失败，窗口已保留，请重试。");
      return;
    }
    WindowCtl.prepareExit();
    Application.quit();
  } catch {
    closingWindow = false;
    toast("关闭未完成，请重试。");
  }
}
async function quitApplication() {
  if (closingWindow) return;
  closingWindow = true;
  try {
    if (!(await flush())) {
      closingWindow = false;
      if (isMac) Application.cancelQuitRequest();
      toast("保存失败，已取消退出，请重试。");
      return;
    }
    await WindowCtl.shutdownService();
    Application.quit();
  } catch {
    closingWindow = false;
    if (isMac) Application.cancelQuitRequest();
    toast("退出未完成，请重试。");
  }
}
Application.on("quitRequest", () => void quitApplication());
Application.on("reopen", () => showMainWindow());
if (isMac) Application.setQuitRequestOptions({ system: true });
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
  const show = () => showMainWindow();
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
  showMainWindow();
  if (unlocked() && !quickAccessOpen()) openQuickAccess();
});

function Workspace() {
  const tool = () => dest() === "generator" || dest() === "health" || dest() === "ai";
  return (
    <View style={{ flex: 1, flexDirection: "row" }}>
      <If when={!sidebarCollapsed()}>
        <Sidebar />
      </If>
      <If when={sidebarCollapsed() && tool()}>
        <View style={{ width: 42, backgroundColor: c().side, borderRightWidth: 1, borderRightColor: c().sideLine, alignItems: "center", paddingTop: 46 }}>
          <IconBtn testID="sidebar-expand-tool-btn" icon="sidebar" label={isMac ? "显示边栏 (⌃⌘S)" : "显示边栏 (Ctrl+Alt+S)"} size={15} onPress={toggleSidebar} />
        </View>
      </If>
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
      <View style={{ pointerEvents: "box-none", position: "absolute", bottom: 34, left: 0, right: 0, alignItems: "center" }}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 12, backgroundColor: "#26354b", borderRadius: 10, paddingHorizontal: 18, paddingVertical: 10, boxShadow: "0 6px 20px rgba(0,0,0,0.22)" }}>
          <T size={12.5} color="#ffffff">{toastText()}</T>
          <If when={toastAction()}>
            <View
              role="button"
              testID="toast-action"
              accessibilityLabel={toastAction()?.label ?? "撤销"}
              onPress={() => {
                const act = toastAction();
                dismissToast();
                act?.onAction();
              }}
              style={{ paddingHorizontal: 10, paddingVertical: 3, borderRadius: 6, backgroundColor: "rgba(255,255,255,0.16)", cursor: "pointer" }}
              hoverStyle={{ backgroundColor: "rgba(255,255,255,0.26)" }}
            >
              <T size={12} weight="600" color="#ffffff">{toastAction()?.label}</T>
            </View>
          </If>
        </View>
      </View>
    </If>
  );
}

// The browser host can unlock the core on a cold start (explicit setting);
// pick that up so the interface follows the core.
let browserStarted = false;

pollEvery(1000, async (isActive) => {
  const requestedPhase = phase();
  if (requestedPhase !== "locked" && requestedPhase !== "unlocked") return;
  const status = await coreApi.status();
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
    </View>
  );
}

mount(App);
