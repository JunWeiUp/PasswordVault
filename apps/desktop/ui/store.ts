import { captureNotes } from "./notes/capture";
// Vault data and actions. All encryption and storage stays in Rust (`Vault`);
// this module keeps the decrypted list the interface shows while unlocked and
// forgets it on lock.
import { batch, computed, effect, signal } from "nsh";
import { Attachments, Browser, Vault } from "passwordvault/native";
import { bindNativeVault } from "./native";
import { clearSearchIndex, searchItems } from "./search";
import { catMatches, isAiActor } from "./notes/knowledge";
import { sortMode } from "./preferences";
import {
  DEST_NAME,
  DEST_TYPES,
  ERROR_TEXT,
  TYPE_NAME,
  destOf,
  errorText,
  inDest,
  type Dest,
  type Item,
  type ItemType,
  type Phase,
} from "./api/vaultMeta";

export { DEST_NAME, DEST_TYPES, ERROR_TEXT, TYPE_NAME, destOf, errorText, inDest, type Dest, type Item, type ItemType, type Phase };

const vault = new Vault();
bindNativeVault(vault);
/** The app's single vault session, for Rust modules that take `Instance<Vault>` (attachments). */
export const vaultInstance = vault;
export const vaultDirectory = vault.directory;

export async function call<T = any>(request: Record<string, unknown>): Promise<T> {
  return JSON.parse(await vault.command(JSON.stringify(request))) as T;
}

// --- State -----------------------------------------------------------------

export const phase = signal<Phase>("loading");
export const items = signal<Item[]>([]);
export const settings = signal<Record<string, any>>({});
export const dest = signal<Dest>("notes");
export const noteCategory = signal<string | null>(null);
export const query = signal("");
export const chip = signal<"all" | "fav" | "ai" | "issue" | "card" | "identity" | "crypto">("all");
export const selection = signal<Partial<Record<Dest, string>>>({});
export const editing = signal(false);
export const saveState = signal<"saved" | "saving" | "failed">("saved");
export const saveError = signal("");
export const toastText = signal("");
export const audit = signal<Record<string, { weak?: boolean; reused?: boolean; expired?: boolean }>>({});

let toastTimer: number | undefined;
export function toast(text: string) {
  toastText.set(text);
  if (toastTimer !== undefined) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastText.set(""), 2600) as unknown as number;
}

export const now = () => new Date().toISOString();
const clone = <T,>(value: T): T => JSON.parse(JSON.stringify(value));

export const noteCategories = computed<string[]>(() => {
  const saved: string[] = Array.isArray(settings().noteCategories) ? settings().noteCategories : [];
  const used = items()
    .filter((i) => i.type === "secureNote" && !i.isDeleted && i.category)
    .map((i) => String(i.category));
  return [...new Set([...saved, ...used])];
});

export const countIn = (d: Dest) => items().filter((i) => inDest(i, d)).length;

export const visible = computed<Item[]>(() => {
  const d = dest();
  const q = query();
  const issues = audit();
  let list = items().filter((i) => inDest(i, d));
  if (d === "notes" && noteCategory()) list = list.filter((i) => catMatches(i.category, noteCategory()));
  const f = chip();
  if (f === "fav") list = list.filter((i) => i.isFavorite);
  if (f === "ai") list = list.filter((i) => isAiActor(i.lastActor));
  if (f === "issue") list = list.filter((i) => issues[i.id]);
  if (f === "card") list = list.filter((i) => i.type === "creditCard");
  if (f === "identity") list = list.filter((i) => i.type === "identity");
  if (f === "crypto") list = list.filter((i) => i.type === "crypto");
  const mode = sortMode();
  const order = (a: Item, b: Item) =>
    mode === "title"
      ? String(a.title ?? "").localeCompare(String(b.title ?? ""), "zh-Hans-CN", { numeric: true, sensitivity: "base" })
      : mode === "created"
        ? String(b.createdAt ?? b.updatedAt ?? "").localeCompare(String(a.createdAt ?? a.updatedAt ?? ""))
        : String(b.updatedAt ?? "").localeCompare(String(a.updatedAt ?? ""));
  return searchItems([...list].sort((a, b) => Number(!!b.isPinned) - Number(!!a.isPinned) || order(a, b)), q);
});

export const selected = computed<Item | undefined>(() => {
  const id = selection()[dest()];
  const list = visible();
  return list.find((i) => i.id === id) ?? list[0];
});

export function select(id: string) {
  batch(() => {
    selection.update((s) => ({ ...s, [dest()]: id }));
    editing.set(false);
  });
}

export function go(d: Dest) {
  batch(() => {
    dest.set(d);
    query.set("");
    chip.set("all");
    editing.set(false);
    if (d !== "notes") noteCategory.set(null);
  });
}

export function reveal(item: Item) {
  batch(() => {
    const d = destOf(item.type);
    dest.set(d);
    noteCategory.set(null);
    query.set("");
    chip.set("all");
    selection.update((s) => ({ ...s, [d]: item.id }));
  });
}

// --- Lifecycle -------------------------------------------------------------

export async function boot() {
  try {
    const status = await call<{ exists: boolean; unlocked: boolean }>({ op: "status" });
    if (!status.exists) phase.set("onboard");
    else if (status.unlocked) await load();
    else phase.set("locked");
  } catch (e) {
    phase.set("locked");
    toast(errorText(e));
  }
}

export async function load() {
  // Notes arrive as summaries (plain text for lists/search); full rich structures
  // load per note (`ensureFull`) to keep unlock memory proportional to what is shown.
  const doc = await call<{ items: Item[]; settings: Record<string, any> }>({ op: "list", summaries: true });
  batch(() => {
    items.set(doc.items ?? []);
    settings.set(doc.settings ?? {});
    phase.set("unlocked");
  });
  refreshAudit();
}

const SUMMARY_ONLY = new Set(["noteDocument", "noteOriginal", "noteSummary", "__noteSearchText"]);
function summaryKey(item: Item): string {
  const fields: Record<string, unknown> = {};
  for (const key of Object.keys(item).sort()) {
    if (!SUMMARY_ONLY.has(key) && !key.startsWith("_")) fields[key] = item[key];
  }
  return JSON.stringify(fields);
}
/** Background refresh (relay sync): replaces only what changed. Unsaved local
 *  edits stay on screen and an open note keeps its loaded full structures, so
 *  the editor is not torn down while the record itself did not change. */
export async function refreshItems() {
  const doc = await call<{ items: Item[]; settings: Record<string, any> }>({ op: "list", summaries: true });
  if (phase() !== "unlocked") return;
  const current = new Map(items().map((i) => [i.id, i]));
  const next = (doc.items ?? []).map((item) => {
    const local = pending.get(item.id);
    if (local) return current.get(item.id) ?? local;
    const old = current.get(item.id);
    if (old && !old.noteSummary && item.noteSummary && summaryKey(old) === summaryKey(item)) return old;
    return item;
  });
  batch(() => {
    items.set(next);
    settings.set(doc.settings ?? {});
  });
  refreshAudit();
}

export async function create(password: string) {
  await call({ op: "create", password });
  await load();
}

export async function unlock(password: string) {
  await call({ op: "unlock", password });
  await load();
}

export async function lock() {
  // Revoke a pending one-time browser startup unlock before anything else, so a
  // manual or system lock can never be undone by the extension.
  try {
    await Browser.cancelStartup();
  } catch {}
  try {
    await (Attachments as any).cleanupSessions?.();
  } catch {}
  await flush();
  try {
    await call({ op: "lock" });
  } finally {
    batch(() => {
      clearSearchIndex();
      items.set([]);
      settings.set({});
      audit.set({});
      selection.set({});
      editing.set(false);
      query.set("");
      phase.set("locked");
    });
    lockListeners.forEach((fn) => fn());
  }
}
/** Drops decrypted items from the interface while the window is hidden; the core
 *  stays as it is (automatic locking still applies) and `load()` restores them. */
export async function releaseForHiddenWindow() {
  await flush();
  batch(() => {
    clearSearchIndex();
    items.set([]);
    audit.set({});
    editing.set(false);
    query.set("");
  });
}

const lockListeners = new Set<() => void>();
/** Runs `fn` whenever the vault locks (generator history, open panels). */
export function onLock(fn: () => void) {
  lockListeners.add(fn);
  return () => lockListeners.delete(fn);
}

// --- Lazy note bodies --------------------------------------------------------

const loadingFull = new Map<string, Promise<Item | undefined>>();
/** The complete item (rich note structures included), fetched once when needed. */
export function ensureFull(id: string): Promise<Item | undefined> {
  const current = items().find((i) => i.id === id);
  if (!current?.noteSummary) return Promise.resolve(current);
  let pending = loadingFull.get(id);
  if (!pending) {
    pending = call<Item>({ op: "get", id })
      .then((full) => {
        const now = items().find((i) => i.id === id);
        // Keep local edits made meanwhile only if they were already full items.
        if (now?.noteSummary) replace(full);
        return items().find((i) => i.id === id);
      })
      .catch((e) => {
        toast(errorText(e));
        return undefined;
      })
      .finally(() => loadingFull.delete(id));
    loadingFull.set(id, pending);
  }
  return pending;
}
/** `item` with its full note structures; flags changed on the summary are kept. */
async function withFull(item: Item): Promise<Item> {
  if (!item.noteSummary) return item;
  const full = await ensureFull(item.id);
  if (!full || full.noteSummary) throw new Error("InvalidData");
  const { noteSummary: _summary, ...changes } = item;
  return { ...full, ...changes };
}
effect(() => {
  const shown = selected();
  if (shown?.noteSummary) void ensureFull(shown.id);
});

// --- Saving ----------------------------------------------------------------

const pending = new Map<string, Item>();
const baselines = new Map<string, { item: Item | undefined; at: string }>();
let saveTimer: number | undefined;

function withPasswordHistory(next: Item, base: Item | undefined, at: string): Item {
  const update = (n: any, old: any) => {
    const password = n.password ?? "";
    if (!old) {
      if (password && !n.passwordLastChanged) n.passwordLastChanged = at;
      return;
    }
    const previous = old.password ?? "";
    if (password === previous) {
      if (old.passwordHistory) n.passwordHistory = old.passwordHistory;
      else delete n.passwordHistory;
      if (old.passwordLastChanged) n.passwordLastChanged = old.passwordLastChanged;
      else delete n.passwordLastChanged;
      return;
    }
    const history = [...(old.passwordHistory ?? [])];
    if (previous) history.unshift({ password: previous, changedAt: at });
    n.passwordHistory = history;
    n.passwordLastChanged = at;
  };
  const result: Item = clone(next);
  update(result, base);
  if (Array.isArray(result.accounts)) {
    for (const account of result.accounts) {
      update(account, base?.accounts?.find((a: any) => a.id === account.id));
    }
  }
  return result;
}

function replace(item: Item) {
  items.update((list) => {
    const index = list.findIndex((i) => i.id === item.id);
    if (index < 0) return [item, ...list];
    const copy = [...list];
    copy[index] = item;
    return copy;
  });
}

/** Applies an edit at once and saves it shortly after (typing coalesces). */
export function edit(id: string, change: (draft: Item) => void) {
  const current = items().find((i) => i.id === id);
  if (!current) return;
  if (current.noteSummary) {
    // Never edit a summary: load the full note first, then apply the change.
    void ensureFull(id).then((full) => full && !full.noteSummary && edit(id, change));
    return;
  }
  let draft: Item = clone(current);
  change(draft);
  if (draft.type === "password" || draft.type === "totp") {
    if (!baselines.has(id)) baselines.set(id, { item: current, at: now() });
    const base = baselines.get(id)!;
    draft = withPasswordHistory(draft, base.item, base.at);
  }
  draft.updatedAt = now();
  replace(draft);
  pending.set(id, draft);
  saveState.set("saving");
  if (saveTimer !== undefined) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => void flush(), 400) as unknown as number;
}

export async function flush() {
  captureNotes();
  if (saveTimer !== undefined) clearTimeout(saveTimer);
  saveTimer = undefined;
  const batchItems = [...pending.values()];
  for (const item of batchItems) {
    try {
      const req: Record<string, unknown> = { op: "save", item: stripLocal(item) };
      if (item.type === "secureNote") {
        req.historyMeta = { actorType: "user", actor: "手动编辑 · 我", coalesce: true };
      }
      const saved = await call<any>(req);
      if (pending.get(item.id) === item) pending.delete(item.id);
      if (saved?.peerBaseHeads) {
        const cur = items().find((i) => i.id === item.id);
        if (cur) replace({ ...cur, _peerBaseHeads: saved.peerBaseHeads, _peerLibrary: saved.peerLibrary });
      }
    } catch (e) {
      saveState.set("failed");
      saveError.set(errorText(e));
      return false;
    }
  }
  if (!pending.size) {
    baselines.clear();
    saveState.set("saved");
    saveError.set("");
    refreshAudit();
  }
  return true;
}

function stripLocal(item: Item) {
  // The core reads `_peerBaseHeads` for conflict checks; other underscore keys are UI-only.
  const out: Item = { ...item };
  for (const key of Object.keys(out)) if (key.startsWith("__")) delete out[key];
  return out;
}

export async function saveNow(input: Item) {
  let item: Item;
  try {
    item = await withFull(input);
  } catch (e) {
    toast(errorText(e));
    return false;
  }
  replace(item);
  pending.set(item.id, item);
  return flush();
}

const BLANK_TITLE: Record<ItemType, string> = {
  password: "未命名账号", totp: "未命名验证码", crypto: "未命名钱包", secureNote: "未命名笔记",
  creditCard: "未命名银行卡", identity: "未命名身份信息", device: "未命名设备",
};

export async function createItem(type: ItemType, extra: Partial<Item> = {}) {
  const at = now();
  const item: Item = {
    id: crypto.randomUUID(), type, title: BLANK_TITLE[type], username: "", note: "", tags: [],
    noteFormat: "plain", isDeleted: false, isFavorite: false, isPinned: false,
    createdAt: at, updatedAt: at,
    ...(type === "totp" ? { period: 30, secret: "" } : {}),
    ...(type === "creditCard" ? { card: {} } : {}),
    ...(type === "identity" ? { identity: {} } : {}),
    ...(type === "secureNote" && noteCategory() ? { category: noteCategory() } : {}),
    ...extra,
  };
  if (!(await saveNow(item))) return;
  batch(() => {
    const d = dest() === "all" || dest() === "favorites" || DEST_TYPES[dest()]?.includes(type) ? dest() : destOf(type);
    dest.set(d);
    query.set("");
    chip.set("all");
    selection.update((s) => ({ ...s, [d]: item.id }));
    editing.set(type !== "secureNote");
  });
  return item;
}

export function toggleFavorite(item: Item) {
  edit(item.id, (d) => (d.isFavorite = !d.isFavorite));
  toast(item.isFavorite ? "已取消收藏" : "已收藏");
}
export function togglePin(item: Item) {
  edit(item.id, (d) => (d.isPinned = !d.isPinned));
}

export async function moveToTrash(item: Item) {
  const ok = await saveNow({ ...item, isDeleted: true, isPinned: false, deletedAt: now(), updatedAt: now() });
  if (ok) toast("已移到回收站，可随时恢复");
}
export async function restore(item: Item) {
  const ok = await saveNow({ ...item, isDeleted: false, deletedAt: "", updatedAt: now() });
  if (ok) {
    reveal(item);
    toast(`已恢复到「${DEST_NAME[destOf(item.type)]}」`);
  }
}
export async function deleteForever(item: Item) {
  try {
    await call({ op: "remove", id: item.id });
    items.update((list) => list.filter((i) => i.id !== item.id));
    toast("已永久删除");
  } catch (e) {
    toast(errorText(e));
  }
}
export async function emptyTrash() {
  for (const item of items().filter((i) => i.isDeleted)) await deleteForever(item);
}

export async function addCategory(name: string) {
  try {
    const clean = name.trim().replace(/^\/+|\/+$/g, "");
    if (!clean) return;
    await call({ op: "category-add", name: clean });
    const doc = await call<{ settings: Record<string, any> }>({ op: "list", summaries: true });
    settings.set(doc.settings ?? {});
    noteCategory.set(clean);
  } catch (e) {
    toast(errorText(e));
  }
}
export async function renameCategory(name: string, to: string) {
  await flush();
  try {
    const cleanTo = to.trim().replace(/^\/+|\/+$/g, "");
    const result = await call<{ updated: number }>({ op: "category-rename", name, to: cleanTo, time: now() });
    await load();
    const sel = noteCategory();
    if (sel && catMatches(sel, name)) {
      noteCategory.set(sel === name ? cleanTo : `${cleanTo}${sel.slice(name.length)}`);
    }
    toast(`已重命名为「${cleanTo}」${result.updated ? `，${result.updated} 篇笔记已移动` : ""}`);
  } catch (e) {
    toast(errorText(e));
  }
}
export async function removeCategory(name: string) {
  await flush();
  try {
    await call({ op: "category-remove", name, time: now() });
    await load();
    if (noteCategory() && catMatches(noteCategory()!, name)) noteCategory.set(null);
    toast(`已删除分类「${name}」，笔记已保留`);
  } catch (e) {
    toast(errorText(e));
  }
}

export async function saveMilestone(id: string, summary: string) {
  if (!(await flush())) return false;
  try {
    const clean = summary.trim();
    if (!clean) return false;
    await call({ op: "history-milestone", id, summary: clean, actor: "手动里程碑" });
    await refreshItems();
    toast(`已保存里程碑版本「${clean}」`);
    return true;
  } catch (e) {
    toast(errorText(e));
    return false;
  }
}

export async function saveSettings(change: Record<string, unknown>) {
  try {
    await call({ op: "settings", settings: change });
    settings.update((s) => ({ ...s, ...change }));
  } catch (e) {
    toast(errorText(e));
  }
}

export async function refreshAudit() {
  try {
    const result = await call<any>({ op: "audit" });
    const map: Record<string, { weak?: boolean; reused?: boolean; expired?: boolean }> = {};
    for (const r of result?.results ?? result ?? []) {
      if (r && (r.weak || r.reused || r.expired)) map[r.id] = { weak: r.weak, reused: r.reused, expired: r.expired };
    }
    audit.set(map);
  } catch {
    audit.set({});
  }
}

export async function totpCode(secret: string, period = 30): Promise<string> {
  if (!secret) return "";
  try {
    const r = await call<{ code: string }>({ op: "totp", secret, period, time: Math.floor(Date.now() / 1000) });
    return r.code;
  } catch {
    return "";
  }
}

export async function generatePassword(options: { length: number; upper: boolean; lower: boolean; digits: boolean; symbols: boolean }) {
  const r = await call<{ password: string }>({ op: "generate", ...options });
  return r.password;
}
