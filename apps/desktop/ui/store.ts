import { captureNotes } from "./notes/capture";
// Vault data and actions. All encryption and storage stays in Rust (`Vault`);
// this module keeps the decrypted list the interface shows while unlocked and
// forgets it on lock.
import { batch, computed, effect, signal } from "nsh";
import { Vault } from "passwordvault/native";
import { bindNativeVault } from "./native";
import { deviceSearchText } from "./devices/model";
import { Browser } from "passwordvault/native";

export type ItemType = "password" | "totp" | "crypto" | "secureNote" | "creditCard" | "identity" | "device";
export type Item = { id: string; type: ItemType; title: string; [key: string]: any };
export type Dest =
  | "all" | "accounts" | "codes" | "wallets" | "notes" | "devices"
  | "favorites" | "trash" | "generator" | "health";
export type Phase = "loading" | "onboard" | "locked" | "unlocked";

export const DEST_TYPES: Partial<Record<Dest, ItemType[]>> = {
  accounts: ["password"],
  codes: ["totp"],
  wallets: ["creditCard", "identity", "crypto"],
  notes: ["secureNote"],
  devices: ["device"],
};
export const DEST_NAME: Record<Dest, string> = {
  all: "全部项目", accounts: "账号", codes: "验证码", wallets: "钱包", notes: "笔记",
  devices: "设备与服务", favorites: "个人收藏", trash: "回收站", generator: "密码生成器", health: "密码健康",
};
export const TYPE_NAME: Record<ItemType, string> = {
  password: "账号", totp: "验证码", crypto: "加密钱包", secureNote: "笔记", creditCard: "银行卡", identity: "身份信息", device: "设备",
};
export const ERROR_TEXT: Record<string, string> = {
  Locked: "密码库已锁定。",
  Authentication: "主密码不正确，或加密数据已损坏。",
  InvalidData: "数据无效或不受支持。",
  AlreadyExists: "该位置已存在密码库。",
  InUse: "密码库正被另一个进程使用。请先退出其他 PasswordVault。",
  Storage: "写入失败，已保留原有数据。",
  StaleEdit: "此条目已在其他设备上修改，请检查后再保存。",
  Unsupported: "此操作不受支持。",
  DevicesUpgradeRequired: "请先启用设备与服务。",
  DevicesSyncBlocked: "对端尚未验证格式兼容性，请升级并解锁对端后重试。对等库暂不支持设备条目同步。",
  UpdateRequired: "请更新客户端以打开此密码库。",
};
export const errorText = (e: unknown) => ERROR_TEXT[String(e).replace(/^Error:\s*/, "")] ?? String(e);

export const destOf = (type: ItemType): Dest =>
  (Object.keys(DEST_TYPES) as Dest[]).find((d) => DEST_TYPES[d]!.includes(type)) ?? "all";

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
export const chip = signal<"all" | "fav" | "issue" | "card" | "identity" | "crypto">("all");
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

export function inDest(item: Item, d: Dest): boolean {
  if (d === "trash") return !!item.isDeleted;
  if (item.isDeleted) return false;
  if (d === "all") return true;
  if (d === "favorites") return !!item.isFavorite;
  return DEST_TYPES[d]?.includes(item.type) ?? false;
}
export const countIn = (d: Dest) => items().filter((i) => inDest(i, d)).length;

function haystack(i: Item) {
  if (i.type === "device") return deviceSearchText(i).toLowerCase();
  return [i.title, i.username, i.url, i.issuer, i.note, i.category, ...(i.tags ?? []), i.network, i.address]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
}

export const visible = computed<Item[]>(() => {
  const d = dest();
  const q = query().trim().toLowerCase();
  const issues = audit();
  let list = items().filter((i) => inDest(i, d));
  if (d === "notes" && noteCategory()) list = list.filter((i) => i.category === noteCategory());
  const f = chip();
  if (f === "fav") list = list.filter((i) => i.isFavorite);
  if (f === "issue") list = list.filter((i) => issues[i.id]);
  if (f === "card") list = list.filter((i) => i.type === "creditCard");
  if (f === "identity") list = list.filter((i) => i.type === "identity");
  if (f === "crypto") list = list.filter((i) => i.type === "crypto");
  if (q) list = list.filter((i) => haystack(i).includes(q));
  return [...list].sort(
    (a, b) =>
      Number(!!b.isPinned) - Number(!!a.isPinned) ||
      String(b.updatedAt ?? "").localeCompare(String(a.updatedAt ?? "")),
  );
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
    Browser.cancelStartup();
  } catch {}
  await flush();
  try {
    await call({ op: "lock" });
  } finally {
    batch(() => {
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
      const saved = await call<any>({ op: "save", item: stripLocal(item) });
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
    await call({ op: "category-add", name });
    const doc = await call<{ settings: Record<string, any> }>({ op: "list" });
    settings.set(doc.settings ?? {});
    noteCategory.set(name.trim());
  } catch (e) {
    toast(errorText(e));
  }
}
export async function removeCategory(name: string) {
  await flush();
  try {
    await call({ op: "category-remove", name, time: now() });
    await load();
    noteCategory.set(null);
    toast(`已删除分类「${name}」，笔记已保留`);
  } catch (e) {
    toast(errorText(e));
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
