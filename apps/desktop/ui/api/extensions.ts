// Generic encrypted pass-through JSON extension helpers (`item.uiMeta` and `settings.uiPrefs`).
// Allows TypeScript UI & workflow features to store arbitrary structured metadata in the
// encrypted vault without adding new schema fields or whitelists in Rust.
import { call, edit, phase, settings, type Item } from "../store";

/** Pure reader for a namespaced object inside `item.uiMeta` (<= 16 KiB in vault-core). */
export function readItemMeta<T extends Record<string, unknown>>(
  item: { uiMeta?: Record<string, any> } | undefined,
  namespace: string,
  fallback: T,
): T {
  const bucket = item?.uiMeta?.[namespace];
  if (bucket && typeof bucket === "object" && !Array.isArray(bucket)) {
    return { ...fallback, ...(bucket as Partial<T>) };
  }
  return { ...fallback };
}

/** Updates a namespaced object inside `item.uiMeta` via the normal encrypted save queue. */
export function patchItemMeta<T extends Record<string, unknown>>(
  itemId: string,
  namespace: string,
  patch: Partial<T>,
): void {
  edit(itemId, (draft) => {
    const base =
      draft.uiMeta && typeof draft.uiMeta === "object" && !Array.isArray(draft.uiMeta)
        ? { ...draft.uiMeta }
        : {};
    const prev =
      base[namespace] && typeof base[namespace] === "object" && !Array.isArray(base[namespace])
        ? { ...base[namespace] }
        : {};
    base[namespace] = { ...prev, ...patch };
    draft.uiMeta = base;
  });
}

/** Pure reader for a key inside encrypted `settings.uiPrefs` (<= 64 KiB in vault-core). */
export function readUiPref<T>(
  sourceSettings: Record<string, any> | undefined,
  key: string,
  fallback: T,
): T {
  const prefs = sourceSettings?.uiPrefs;
  if (prefs && typeof prefs === "object" && !Array.isArray(prefs) && key in prefs && prefs[key] !== undefined) {
    return prefs[key] as T;
  }
  return fallback;
}

/** Reads a preference from the live reactive vault settings signal. */
export function getUiPref<T>(key: string, fallback: T): T {
  return readUiPref(settings(), key, fallback);
}

/** Persists a preference into encrypted `settings.uiPrefs` via generic settings pass-through. */
export async function setUiPref<T>(key: string, value: T): Promise<void> {
  const current =
    settings().uiPrefs && typeof settings().uiPrefs === "object" && !Array.isArray(settings().uiPrefs)
      ? { ...settings().uiPrefs }
      : {};
  current[key] = value;
  settings.update((s) => ({ ...s, uiPrefs: current }));
  if (phase() !== "unlocked") return;
  try {
    await call({ op: "settings", settings: { uiPrefs: current } });
  } catch {
    // Non-critical UI preference; keep live state without disturbing editing.
  }
}
