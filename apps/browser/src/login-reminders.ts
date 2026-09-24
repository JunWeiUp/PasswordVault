import { reminderPattern, webOrigin } from "./security";
import type { Request } from "./core";

type PendingLogin = {
  id: string;
  origin: string;
  tabId: number;
  username: string;
  password: string;
  expires: number;
};
const TTL = 120_000;
const pending = new Map<number, PendingLogin>();
let generation = 0;
const tabGenerations = new Map<number, number>();
const knownOrigins = new Map<number, string>();
export function loginCaptureEpoch(sender: chrome.runtime.MessageSender) {
  const tabId = sender.tab?.id;
  if (
    sender.id === chrome.runtime.id &&
    tabId &&
    sender.url &&
    !knownOrigins.has(tabId)
  ) {
    try {
      knownOrigins.set(tabId, webOrigin(sender.tab?.url ?? sender.url));
    } catch {
      /* validated by handler */
    }
  }
  return { global: generation, tab: tabGenerations.get(tabId ?? -1) ?? 0 };
}
const passwordFrames = new Map<number, Map<number, boolean>>();
const timers = new Map<number, ReturnType<typeof setTimeout>>();
function notice(value: PendingLogin) {
  return { id: value.id, origin: value.origin, expires: value.expires };
}
function announcePending(tabId: number, value: PendingLogin) {
  void chrome.tabs
    .sendMessage(
      tabId,
      { action: "reminder-pending", notice: notice(value) },
      { frameId: 0 },
    )
    .catch(() => {});
}
const siteBadges = new Map<
  number,
  { origin: string; count: number; hasPassword: boolean }
>();

function renderBadge(tabId: number) {
  const site = siteBadges.get(tabId);
  const waiting = pending.get(tabId);
  const hasPending = !!waiting && waiting.expires > Date.now();
  const text = hasPending
    ? "+"
    : site && (site.count > 0 || site.hasPassword)
      ? site.count > 99
        ? "99+"
        : String(site.count)
      : "";
  const title = hasPending
    ? "PasswordVault · 有待确认保存的登录"
    : site && site.count > 0
      ? `PasswordVault · 本站有 ${site.count} 个账号`
      : site?.hasPassword
        ? "PasswordVault · 检测到密码框，本站还没有保存的账号"
        : "PasswordVault";
  void chrome.action
    .setBadgeBackgroundColor({
      tabId,
      color: hasPending ? "#b56a00" : "#255ad7",
    })
    .catch(() => {});
  void chrome.action.setBadgeText({ tabId, text }).catch(() => {});
  void chrome.action.setTitle({ tabId, title }).catch(() => {});
}

export function setAccountBadge(
  tabId: number,
  origin: string,
  count: number,
  hasPassword?: boolean,
) {
  const previous = siteBadges.get(tabId);
  siteBadges.set(tabId, {
    origin,
    count,
    hasPassword:
      hasPassword ?? (previous?.origin === origin && previous.hasPassword),
  });
  renderBadge(tabId);
}

export function clearAccountBadge(tabId: number) {
  passwordFrames.delete(tabId);
  siteBadges.delete(tabId);
  clearPending(tabId);
}
export async function reminderEnabled(origin: string) {
  const stored = (await chrome.storage.local.get("reminderDisabledOrigins"))
    .reminderDisabledOrigins;
  const disabled: string[] = Array.isArray(stored) ? stored : [];
  return (
    !disabled.includes(origin) &&
    (await chrome.permissions.contains({ origins: [reminderPattern(origin)] }))
  );
}

export async function configureReminder(
  origin: string,
  enabled: boolean,
  tabId: number,
) {
  const stored = (await chrome.storage.local.get("reminderDisabledOrigins"))
    .reminderDisabledOrigins;
  const disabled: string[] = Array.isArray(stored) ? stored : [];
  if (
    enabled &&
    !(await chrome.permissions.contains({ origins: [reminderPattern(origin)] }))
  )
    throw new Error("site-permission");
  await chrome.storage.local.set({
    reminderDisabledOrigins: enabled
      ? disabled.filter((o) => o !== origin)
      : [...new Set([...disabled, origin])],
  });
  // Apply the user's exception to every open tab on this exact origin.
  const tabs = await chrome.tabs.query({ url: reminderPattern(origin) });
  for (const tab of tabs) {
    if (!tab.id || !tab.url || webOrigin(tab.url) !== origin) continue;
    if (enabled)
      await chrome.scripting
        .executeScript({
          target: { tabId: tab.id, allFrames: true },
          files: ["login-observer.js"],
        })
        .catch(() => {});
    else clearPending(tab.id);
    await chrome.tabs
      .sendMessage(tab.id, {
        action: enabled ? "reminder-enabled" : "reminder-disabled",
      })
      .catch(() => {});
  }
  if (!enabled) clearPending(tabId);
}

export function clearPending(tabId: number, invalidate = true) {
  if (invalidate)
    tabGenerations.set(tabId, (tabGenerations.get(tabId) ?? 0) + 1);
  const value = pending.get(tabId);
  if (value) {
    value.password = "";
    value.username = "";
  }
  pending.delete(tabId);
  clearTimeout(timers.get(tabId));
  timers.delete(tabId);
  renderBadge(tabId);
  if (value)
    void chrome.tabs
      .sendMessage(
        tabId,
        { action: "reminder-cleared", id: value.id },
        { frameId: 0 },
      )
      .catch(() => {});
}

export function clearAllPending() {
  generation++;
  const tabs = new Set([...pending.keys(), ...siteBadges.keys()]);
  siteBadges.clear();
  for (const id of tabs) clearPending(id);
}

export function pendingLogin(tabId: number, origin: string) {
  const value = pending.get(tabId);
  if (value && (value.origin !== origin || value.expires <= Date.now())) {
    clearPending(tabId);
    return undefined;
  }
  return value;
}

// Never trust origin/tabId from page payloads; derive them exclusively from Chrome's sender.
export async function handleLoginPage(
  request: Record<string, any>,
  sender: chrome.runtime.MessageSender,
  core: (request: Request) => Promise<any>,
  capturedEpoch = loginCaptureEpoch(sender),
) {
  if (
    sender.id !== chrome.runtime.id ||
    typeof sender.frameId !== "number" ||
    sender.frameId < 0 ||
    (sender.frameId !== 0 && !sender.documentId) ||
    !sender.tab?.id ||
    !sender.url
  )
    throw new Error("forbidden");
  const tabId = sender.tab.id;
  const origin = webOrigin(sender.url);
  const ensureCurrent = () => {
    if (
      capturedEpoch.global !== generation ||
      capturedEpoch.tab !== (tabGenerations.get(tabId) ?? 0)
    )
      throw new Error("cancelled");
  };
  if (request.action === "login-submitted") ensureCurrent();
  if (sender.origin && sender.origin !== origin) throw new Error("forbidden");
  const tab = await chrome.tabs.get(tabId);
  if (request.action === "login-submitted") ensureCurrent();
  if (!tab.url || webOrigin(tab.url) !== origin)
    throw new Error("changed-origin");
  knownOrigins.set(tabId, origin);
  const enabled = await reminderEnabled(origin);
  if (request.action === "login-submitted") ensureCurrent();
  if (request.action === "login-pending") {
    try {
      const accounts = await core({ op: "matches", origin });
      const frames = passwordFrames.get(tabId) ?? new Map<number, boolean>();
      frames.set(sender.frameId, request.hasPassword === true);
      passwordFrames.set(tabId, frames);
      setAccountBadge(
        tabId,
        origin,
        accounts.length,
        [...frames.values()].some(Boolean),
      );
    } catch {
      clearAccountBadge(tabId);
      return { enabled, pending: false };
    }
    const value = enabled ? pendingLogin(tabId, origin) : undefined;
    return value
      ? { enabled, pending: true, notice: notice(value) }
      : { enabled, pending: false };
  }
  if (!enabled) {
    throw new Error("forbidden");
  }
  if (request.action === "login-dismiss") {
    if (sender.frameId !== 0) throw new Error("forbidden");
    clearPending(tabId);
    return {};
  }
  if (request.action === "login-open") {
    if (sender.frameId !== 0) throw new Error("forbidden");
    if (!pendingLogin(tabId, origin)) throw new Error("expired");
    await core({ op: "matches", origin });
    try {
      await chrome.action.openPopup({ windowId: tab.windowId });
    } catch {
      // Some Chromium shells do not implement action popups for their task windows.
      await chrome.tabs.create({
        url: chrome.runtime.getURL(`popup.html?sourceTabId=${tabId}`),
      });
    }
    return {};
  }
  if (request.action !== "login-submitted") throw new Error("forbidden");
  if (
    typeof request.username !== "string" ||
    typeof request.password !== "string" ||
    !request.username.trim() ||
    !request.password ||
    request.username.length > 4096 ||
    request.password.length > 4096
  )
    throw new Error("invalid");
  // Do not retain page credentials if the vault is locked or unavailable.
  try {
    const accounts = await core({ op: "matches", origin });
    ensureCurrent();
    setAccountBadge(tabId, origin, accounts.length, true);
    for (const account of accounts.filter(
      (a: any) => a.username === request.username,
    )) {
      const existing = await core({
        op: "fill",
        origin,
        id: account.id,
        accountId: account.accountId,
      });
      const same =
        existing.username === request.username &&
        existing.password === request.password;
      existing.password = "";
      ensureCurrent();
      if (same) {
        clearPending(tabId);
        return { duplicate: true };
      }
    }
    const current = await chrome.tabs.get(tabId);
    if (
      !current.url ||
      webOrigin(current.url) !== origin ||
      !(await reminderEnabled(origin))
    )
      throw new Error("changed-origin");
    ensureCurrent();
    const previous = pendingLogin(tabId, origin);
    if (
      previous?.username === request.username &&
      previous.password === request.password
    )
      return { pending: true, notice: notice(previous) };
    clearPending(tabId, false);
    const value: PendingLogin = {
      id: crypto.randomUUID(),
      tabId,
      origin,
      username: request.username,
      password: request.password,
      expires: Date.now() + TTL,
    };
    pending.set(tabId, value);
    timers.set(
      tabId,
      setTimeout(() => clearPending(tabId), TTL),
    );
    renderBadge(tabId);
    // A submit response may belong to a document that has already navigated away.
    announcePending(tabId, value);
    return { pending: true, notice: notice(value) };
  } catch (error) {
    // Embedded login UI may disappear immediately. Only the main document owns
    // notices, and messages to it never contain the submitted credential.
    if (
      error instanceof Error &&
      ["locked", "unpaired", "native-unavailable", "not-running"].includes(
        error.message,
      )
    ) {
      void chrome.tabs
        .sendMessage(
          tabId,
          { action: "reminder-unavailable", origin },
          { frameId: 0 },
        )
        .catch(() => {});
    }
    throw error;
  }
}

chrome.tabs.onRemoved.addListener(clearAccountBadge);
chrome.tabs.onUpdated.addListener((id, change, tab) => {
  if (change.url) passwordFrames.delete(id);
  const url =
    change.url ?? (change.status === "complete" ? tab?.url : undefined);
  if (!url) return;
  try {
    const origin = webOrigin(url);
    if (knownOrigins.has(id) && knownOrigins.get(id) !== origin)
      clearPending(id);
    knownOrigins.set(id, origin);
    if (siteBadges.get(id)?.origin !== origin) siteBadges.delete(id);
    const value = pendingLogin(id, origin);
    if (value) announcePending(id, value);
    renderBadge(id);
  } catch {
    clearAccountBadge(id);
  }
});
chrome.permissions.onRemoved.addListener(() => {
  clearAllPending();
});
