import type { Item } from "../store";
export const normalizeSecret = (value: string) => value.replace(/\s/g, "").toUpperCase();
export const validPeriod = (value: unknown) => Number.isInteger(Number(value)) && Number(value) >= 1 && Number(value) <= 86400;
export function setupLink(item: Partial<Item>): string {
  return `otpauth://totp/${encodeURIComponent(`${item.title ?? ""}:${item.username ?? ""}`)}?secret=${encodeURIComponent(normalizeSecret(item.secret ?? ""))}&issuer=${encodeURIComponent(item.title ?? "")}&period=${item.period ?? 30}&algorithm=SHA1&digits=6`;
}
/** Separators accepted between sites in an account's `url` field (core matching uses the same set). */
export const SITE_SEPARATORS = /[\s,;]+/;
export function websites(value: string): string[] {
  return value.split(SITE_SEPARATORS).filter(Boolean).flatMap(part => {
    const candidate = part.includes(":") ? part : `https://${part}`;
    return /^https?:\/\/[^\s/]+(?:\/.*)?$/i.test(candidate) ? [candidate] : [];
  });
}
let sequence = 0;
export const newID = () => `entry-${Date.now().toString(36)}-${++sequence}-${Math.random().toString(36).slice(2)}`;
export function normalizeAccountIDs(accounts: any[]): any[] {
  const seen = new Set<string>();
  return accounts.map(a => { let id = a.id; if (!id || seen.has(id)) id = newID(); seen.add(id); return { ...a, id }; });
}
export const colors = ["", "红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "粉色", "青色"];

/** Hostname without "www.", lower-cased; "" when the value is not a web address. */
export function hostOf(url: string): string {
  try { return new URL(url.includes("://") ? url : `https://${url}`).hostname.replace(/^www\./, "").toLowerCase(); } catch { return ""; }
}
/** The raw site entries of an account (kept verbatim for editing). */
export const siteEntries = (value: string): string[] => value.split(SITE_SEPARATORS).filter(Boolean);
