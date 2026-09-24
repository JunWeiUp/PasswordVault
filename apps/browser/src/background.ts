import { handleInline, clearInlineOffers } from "./inline-fill";
import { nativeTransportError } from "./native-connection";
import { readStorage } from "./storage";
import * as vaultCore from "./core";
import { trustedUI, webOrigin } from "./security";
import type { Request } from "./core";
import {
  clearAllPending,
  clearPending,
  configureReminder,
  handleLoginPage,
  loginCaptureEpoch,
  pendingLogin,
  reminderEnabled,
  setAccountBadge,
  clearAccountBadge,
} from "./login-reminders";
const HOST = "com.securepass.vault.native_v2";
let core: typeof import("./core") | undefined;
let serial: Promise<unknown> = Promise.resolve();
async function mode(): Promise<string> {
  return (await chrome.storage.local.get("mode")).mode ?? "native";
}
async function native(request: Record<string, unknown>) {
  const { token } = await chrome.storage.local.get("token");
  let response;
  try {
    response = await chrome.runtime.sendNativeMessage(HOST, {
      version: 2,
      token,
      ...request,
    });
  } catch (error) {
    throw new Error(nativeTransportError(error));
  }
  if (!response?.ok) {
    if (["locked", "unpaired"].includes(response?.error)) clearAllPending();
    clearInlineOffers();
    if (response?.error === "unpaired")
      await chrome.storage.local.remove("token");
    throw new Error(response?.error ?? "native-unavailable");
  }
  return response;
}
async function currentTab(id?: number) {
  const tab =
    id === undefined
      ? (await chrome.tabs.query({ active: true, currentWindow: true }))[0]
      : await chrome.tabs.get(id);
  if (!tab?.id || !tab.url) throw new Error("invalid-origin");
  return { id: tab.id, origin: webOrigin(tab.url) };
}
async function requestCore(request: Request) {
  if ((await mode()) === "native") return (await native(request)).data;
  if (!core || core.locked()) throw new Error("locked");
  return core.command(request);
}
async function handle(request: Record<string, any>) {
  switch (request.action) {
    case "status": {
      const chosen = await mode();
      if (chosen === "native") {
        try {
          const s = await native({ op: "status" });
          if (!s.unlocked || s.paired === false) {
            clearAllPending();
            clearInlineOffers();
          }
          if (s.unlocked && s.paired === false)
            await chrome.storage.local.remove("token");
          return {
            mode: chosen,
            available: true,
            unlocked: s.unlocked === true,
            paired:
              typeof s.paired === "boolean"
                ? s.paired
                : !!(await chrome.storage.local.get("token")).token,
          };
        } catch (error) {
          clearAllPending();
          clearInlineOffers();
          return {
            mode: chosen,
            unlocked: false,
            paired: false,
            available: false,
            connectionError:
              error instanceof Error ? error.message : "native-unavailable",
          };
        }
      }
      return {
        mode: chosen,
        exists: !!(await readStorage()),
        unlocked: !!core && !core.locked(),
      };
    }
    case "mode":
      if (!["native", "independent"].includes(request.mode))
        throw new Error("invalid");
      core?.lock();
      clearAllPending();
      clearInlineOffers();
      await chrome.storage.local.set({ mode: request.mode });
      return {};
    case "pair": {
      const r = await native({ op: "pair" });
      if (typeof r.token !== "string" || !r.token || r.token.length > 4096)
        throw new Error("native-unavailable");
      await chrome.storage.local.set({ token: r.token });
      return {};
    }
    case "open-native":
      await native({ op: "open" });
      return {};
    case "unlock": {
      if (
        (await mode()) !== "independent" ||
        !Array.isArray(request.key) ||
        request.key.length !== 32
      )
        throw new Error("invalid");
      core ??= vaultCore;
      const key = Uint8Array.from(request.key);
      request.key.fill(0);
      try {
        await core.unlock(request.storage, key, request.create === true);
      } finally {
        key.fill(0);
      }
      return {};
    }
    case "lock":
      clearAllPending();
      clearInlineOffers();
      if ((await mode()) === "native") await native({ op: "lock" });
      else core?.lock();
      return {};
    case "command":
      if ((await mode()) !== "independent") throw new Error("native-app");
      return requestCore(request.request);
    case "matches": {
      const tab = await currentTab(request.tabId);
      const accounts = await requestCore({ op: "matches", origin: tab.origin });
      setAccountBadge(tab.id, tab.origin, accounts.length);
      const pending = pendingLogin(tab.id, tab.origin);
      return {
        ...tab,
        accounts,
        reminders: await reminderEnabled(tab.origin),
        pending: pending ? { ...pending } : undefined,
      };
    }
    case "configure-reminder": {
      const tab = await currentTab(request.tabId);
      if (tab.origin !== request.origin || typeof request.enabled !== "boolean")
        throw new Error("changed-origin");
      await configureReminder(tab.origin, request.enabled, tab.id);
      return {};
    }
    case "dismiss-pending": {
      const tab = await currentTab(request.tabId);
      if (tab.origin !== request.origin) throw new Error("changed-origin");
      if (pendingLogin(tab.id, tab.origin)?.id === request.id)
        clearPending(tab.id);
      return {};
    }
    case "edit-native-entry": {
      if ((await mode()) !== "native") throw new Error("native-app");
      const tab = await currentTab(request.tabId);
      if (tab.origin !== request.origin) throw new Error("changed-origin");
      if (
        typeof request.id !== "string" ||
        !request.id ||
        request.id.length > 4096 ||
        (request.accountId !== undefined &&
          (typeof request.accountId !== "string" ||
            request.accountId.length > 4096))
      )
        throw new Error("invalid-entry");
      const accounts = await requestCore({ op: "matches", origin: tab.origin });
      if (
        !accounts.some(
          (account: any) =>
            account.id === request.id &&
            (account.accountId ?? "") === (request.accountId ?? ""),
        )
      )
        throw new Error("invalid-entry");
      const current = await currentTab(tab.id);
      if (current.origin !== tab.origin) throw new Error("changed-origin");
      await native({
        op: "open-entry",
        id: request.id,
        accountId: request.accountId,
        origin: tab.origin,
      });
      return {};
    }
    case "fill": {
      const tab = await currentTab(request.tabId);
      if (tab.origin !== request.origin) throw new Error("changed-origin");
      const credential = await requestCore({
        op: "fill",
        origin: tab.origin,
        id: request.id,
        accountId: request.accountId,
      });
      const current = await currentTab(tab.id);
      if (current.origin !== tab.origin) throw new Error("changed-origin");
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        files: ["content.js"],
      });
      try {
        const filled = await chrome.tabs.sendMessage(
          tab.id,
          { action: "vault-fill", origin: tab.origin, ...credential },
          { frameId: 0 },
        );
        if (!filled?.ok) throw new Error("fill");
      } finally {
        credential.password = "";
        credential.username = "";
      }
      return {};
    }
    case "capture": {
      const tab = await currentTab(request.tabId);
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        files: ["content.js"],
      });
      const captured = await chrome.tabs.sendMessage(
        tab.id,
        { action: "vault-capture", origin: tab.origin },
        { frameId: 0 },
      );
      if (!captured?.ok) throw new Error("capture");
      return { ...captured, origin: tab.origin, tabId: tab.id };
    }
    case "save-captured": {
      const tab = await currentTab(request.tabId);
      if (
        tab.origin !== request.origin ||
        typeof request.username !== "string" ||
        typeof request.password !== "string" ||
        request.password.length > 4096 ||
        request.username.length > 4096
      )
        throw new Error("invalid");
      if ((await mode()) === "native")
        await native({
          op: "save",
          origin: tab.origin,
          username: request.username,
          password: request.password,
        });
      else
        await requestCore({
          op: "save",
          item: {
            id: crypto.randomUUID(),
            type: "password",
            title: new URL(tab.origin).hostname,
            url: tab.origin,
            username: request.username,
            password: request.password,
            updatedAt: new Date().toISOString(),
          },
        });
      clearPending(tab.id);
      try {
        const accounts = await requestCore({
          op: "matches",
          origin: tab.origin,
        });
        setAccountBadge(tab.id, tab.origin, accounts.length);
      } catch {
        clearAccountBadge(tab.id);
      }
      return {};
    }
    default:
      throw new Error("unsupported");
  }
}
chrome.runtime.onMessage.addListener((request, sender, respond) => {
  const inlineAction = [
    "inline-availability",
    "inline-accounts",
    "inline-fill",
  ].includes(request?.action);
  const pageAction = [
    "login-submitted",
    "login-pending",
    "login-dismiss",
    "login-open",
  ].includes(request?.action);
  const captureEpoch =
    request?.action === "login-submitted"
      ? loginCaptureEpoch(sender)
      : undefined;
  if (!pageAction && !inlineAction && !trustedUI(sender)) {
    respond({ ok: false, error: "forbidden" });
    return false;
  }
  // A user's dismissal must invalidate an in-flight capture immediately, rather
  // than wait behind the capture's pending native request in the serial queue.
  const bypassSerial =
    (pageAction && request.action === "login-dismiss") ||
    (!pageAction &&
      !inlineAction &&
      (request.action === "dismiss-pending" ||
        (request.action === "configure-reminder" &&
          request.enabled === false)));
  if (!pageAction && !inlineAction && request.action === "lock") {
    clearAllPending();
    clearInlineOffers();
  }
  const work = bypassSerial
    ? pageAction
      ? handleLoginPage(request, sender, requestCore, captureEpoch)
      : handle(request)
    : serial.then(() =>
        inlineAction
          ? handleInline(request, sender, requestCore)
          : pageAction
            ? handleLoginPage(request, sender, requestCore, captureEpoch)
            : handle(request),
      );
  if (!bypassSerial) serial = work.catch(() => {});
  work.then(
    (data) => respond({ ok: true, data }),
    (error) =>
      respond({
        ok: false,
        error: error instanceof Error ? error.message : "failed",
      }),
  );
  return true;
});
chrome.idle.onStateChanged.addListener((state) => {
  if (state !== "active") {
    core?.lock();
    clearAllPending();
    clearInlineOffers();
  }
});
chrome.idle.setDetectionInterval(3600);
chrome.tabs.onActivated.addListener(({ tabId }) => {
  const work = serial.then(async () => {
    try {
      const tab = await currentTab(tabId);
      const accounts = await requestCore({ op: "matches", origin: tab.origin });
      setAccountBadge(tabId, tab.origin, accounts.length);
    } catch {
      clearAccountBadge(tabId);
    }
  });
  serial = work.catch(() => {});
});
chrome.runtime.onInstalled.addListener(() => {
  void chrome.scripting
    .getRegisteredContentScripts()
    .then((scripts) => {
      const ids = scripts
        .filter((script) => script.id.startsWith("login-"))
        .map((script) => script.id);
      if (ids.length) return chrome.scripting.unregisterContentScripts({ ids });
    })
    .catch(() => {});
});
