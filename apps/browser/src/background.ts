import {
  enqueue,
  queuedCount,
  syncQueue,
  type QueuedLogin,
} from "./offline-queue";
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
let readGeneration = 0;
async function mode(): Promise<string> {
  return (await chrome.storage.local.get("mode")).mode ?? "native";
}
async function native(request: Record<string, unknown>) {
  const { token } = await chrome.storage.local.get("token");
  const { syncToken } = await chrome.storage.local.get("syncToken");
  let response;
  try {
    response = await chrome.runtime.sendNativeMessage(HOST, {
      version: 2,
      token,
      syncToken,
      ...request,
    });
  } catch (error) {
    throw new Error(nativeTransportError(error));
  }
  if (!response?.ok) {
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
  if ((await mode()) === "native") {
    const generation = readGeneration;
    if (["matches", "fill"].includes(request.op) &&
        (await chrome.storage.session.get("nativeReadsLocked")).nativeReadsLocked)
      throw new Error("locked");
    const result = (await native(request)).data;
    if (generation !== readGeneration) {
      if (result && typeof result === "object") { result.password = ""; result.username = ""; }
      throw new Error("locked");
    }
    return result;
  }
  if (!core || core.locked()) throw new Error("locked");
  return core.command(request);
}
const offlineErrors = new Set([
  "locked",
  "unpaired",
  "native-unavailable",
  "not-running",
  "native-host-missing",
  "native-host-forbidden",
]);
async function reminderCore(request: Request) {
  try {
    return await requestCore(request);
  } catch (error) {
    if (
      request.op === "matches" &&
      (await mode()) === "native" &&
      error instanceof Error &&
      offlineErrors.has(error.message)
    )
      return [];
    throw error;
  }
}
async function deliverQueued(login: QueuedLogin) {
  // Compare exact credentials before retrying: a lost acknowledgement must not
  // create a duplicate. A changed password is preserved as a separate record.
  const accounts = (await native({ op: "matches", origin: login.origin })).data;
  for (const account of accounts.filter(
    (a: any) => a.username === login.username,
  )) {
    const existing = (
      await native({
        op: "fill",
        origin: login.origin,
        id: account.id,
        accountId: account.accountId,
      })
    ).data;
    const same =
      existing.username === login.username &&
      existing.password === login.password;
    existing.password = "";
    if (same) return;
  }
  await native({ op: "save", ...login });
}
async function updateSyncAlarm() {
  if ((await mode()) === "native" && (await queuedCount()) > 0)
    await chrome.alarms.create("offline-sync", { periodInMinutes: 1 });
  else await chrome.alarms.clear("offline-sync");
}
async function synchronize() {
  if ((await mode()) !== "native" || !(await queuedCount())) {
    await updateSyncAlarm();
    return;
  }
  const s = await native({ op: "status" });
  if (s.syncReady === true) {
    await syncQueue(async (login, id) => {
      const result = await native({ op: "sync-save", ...login, id });
      if (result.data?.saved !== true) throw new Error("failed");
    });
  } else if (s.unlocked && s.paired === true) await syncQueue(deliverQueued);
  await updateSyncAlarm();
}
async function handle(request: Record<string, any>) {
  switch (request.action) {
    case "status": {
      const chosen = await mode();
      if (chosen === "native") {
        try {
          const s = await native({ op: "status" });
          const readsLocked = (await chrome.storage.session.get("nativeReadsLocked")).nativeReadsLocked === true;
          const readReady = s.readReady === true && !readsLocked;
          if ((!s.unlocked || s.paired === false) && !readReady) {
            clearInlineOffers();
          }
          if (s.unlocked && s.paired === false)
            await chrome.storage.local.remove("token");
          let syncError = false;
          if (s.syncReady === true || (s.unlocked && s.paired === true)) {
            try {
              await synchronize();
            } catch {
              syncError = true;
            }
          }
          return {
            queued: await queuedCount(),
            syncError,
            syncSupported: s.syncSupported === true,
            syncReady: s.syncReady === true,
            readReady, readsLocked,
            autoUnlockReady: s.autoUnlockReady === true,
            desktopUnlocked: s.unlocked === true,
            mode: chosen,
            available: true,
            unlocked: !readsLocked && (s.unlocked === true || readReady),
            paired: readReady ||
              (typeof s.paired === "boolean"
                ? s.paired
                : !!(await chrome.storage.local.get("token")).token),
          };
        } catch (error) {
          clearInlineOffers();
          return {
            mode: chosen,
            unlocked: false,
            paired: false,
            available: false,
            queued: await queuedCount(),
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
      await updateSyncAlarm();
      return {};
    case "configure-sync": {
      if ((await mode()) !== "native" || typeof request.password !== "string" ||
          !request.password || new TextEncoder().encode(request.password).length > 4096)
        throw new Error("invalid-credential");
      const { syncToken: previousToken } = await chrome.storage.local.get("syncToken");
      const syncToken = Array.from(crypto.getRandomValues(new Uint8Array(32)),
        (byte) => byte.toString(16).padStart(2, "0")).join("");
      // Fresh identity also permits reauthorization after an ad-hoc signing change.
      // Store before transport: a lost success reply must remain recoverable.
      await chrome.storage.local.set({ syncToken });
      try {
        await native({ op: "configure-sync", password: request.password,
          allowRead: request.allowRead === true, autoUnlock: request.autoUnlock === true });
        await chrome.storage.session.remove("nativeReadsLocked");
      } catch (error) {
        if (error instanceof Error && ["authentication", "sync-keychain"].includes(error.message)) {
          if (previousToken) await chrome.storage.local.set({ syncToken: previousToken });
          else await chrome.storage.local.remove("syncToken");
        }
        throw error;
      } finally { request.password = ""; }
      if (previousToken) {
        try { await native({ op: "disable-sync", syncToken: previousToken }); }
        catch { /* a previous signing identity may no longer have Keychain access */ }
      }
      await synchronize();
      try {
        const tab = await currentTab();
        const accounts = await reminderCore({op:"matches",origin:tab.origin});
        setAccountBadge(tab.id,tab.origin,accounts.length);
      } catch { /* unsupported active pages have no site badge */ }
      return {};
    }
    case "disable-auto-unlock":
      if ((await mode()) !== "native") throw new Error("native-app");
      await native({op:"disable-auto-unlock"});
      return {};
    case "disable-sync":
      if ((await mode()) !== "native") throw new Error("native-app");
      await native({ op: "disable-sync" });
      await chrome.storage.local.remove("syncToken");
      readGeneration++;
      clearInlineOffers();
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
      if ((await mode()) === "native") {
        readGeneration++;
        await chrome.storage.session.set({nativeReadsLocked:true});
        try { await native({op:"lock"}); }
        catch (error) {
          if (!(error instanceof Error) || !offlineErrors.has(error.message)) throw error;
        }
      } else core?.lock();
      return {};
    case "command":
      if ((await mode()) !== "independent") throw new Error("native-app");
      return requestCore(request.request);
    case "matches": {
      const tab = await currentTab(request.tabId);
      const accounts = await reminderCore({
        op: "matches",
        origin: tab.origin,
      });
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
    case "reveal-account": {
      const generation = readGeneration;
      const tab = await currentTab(request.tabId);
      if (tab.origin !== request.origin) throw new Error("changed-origin");
      if (typeof request.id !== "string" || !request.id || request.id.length > 4096 ||
          (request.accountId !== undefined && typeof request.accountId !== "string"))
        throw new Error("invalid-entry");
      const credential = await requestCore({op:"fill",origin:tab.origin,id:request.id,accountId:request.accountId});
      try {
        const current = await currentTab(tab.id);
        if (current.origin !== tab.origin) throw new Error("changed-origin");
        if (generation !== readGeneration) throw new Error("locked");
        return {username:credential.username,password:credential.password};
      } finally { credential.password=""; credential.username=""; }
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
      if (tab.origin !== request.origin) throw new Error("changed-origin");
      if (request.mode && request.mode !== (await mode()))
        throw new Error("changed-mode");
      if (
        typeof request.username !== "string" ||
        typeof request.password !== "string" ||
        !request.password ||
        !request.username.trim() ||
        new TextEncoder().encode(request.password).length > 4096 ||
        new TextEncoder().encode(request.username).length > 4096
      )
        throw new Error("invalid-credential");
      let queued = false;
      if ((await mode()) === "native") {
        // Persist before attempting transport: timeouts may follow a successful save.
        await enqueue({
          origin: tab.origin,
          username: request.username,
          password: request.password,
        });
        await updateSyncAlarm();
        try {
          await synchronize();
        } catch {
          /* retained for retry */
        }
        queued = (await queuedCount()) > 0;
      } else
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
      return { queued };
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
    readGeneration++;
    clearAllPending();
    clearInlineOffers();
  }
  const work = bypassSerial
    ? pageAction
      ? handleLoginPage(request, sender, reminderCore, captureEpoch)
      : handle(request)
    : serial.then(() =>
        inlineAction
          ? handleInline(request, sender, requestCore)
          : pageAction
            ? handleLoginPage(request, sender, reminderCore, captureEpoch)
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
    readGeneration++;
    void chrome.storage.session.set({nativeReadsLocked:true});
    clearAllPending();
    clearInlineOffers();
  }
});
chrome.idle.setDetectionInterval(3600);
chrome.tabs.onActivated.addListener(({ tabId }) => {
  const work = serial.then(async () => {
    try {
      const tab = await currentTab(tabId);
      const accounts = await reminderCore({
        op: "matches",
        origin: tab.origin,
      });
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

// Alarms wake suspended MV3 workers; syncing does not depend on an open popup.
void updateSyncAlarm().catch(() => {});
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== "offline-sync") return;
  const work = serial.then(synchronize);
  serial = work.catch(() => {});
});
