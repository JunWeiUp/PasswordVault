import type { Item } from "../store";
export const normalizeSecret = (value: string) => value.replace(/\s/g, "").toUpperCase();
export const validPeriod = (value: unknown) => Number.isInteger(Number(value)) && Number(value) >= 1 && Number(value) <= 86400;
export function setupLink(item: Partial<Item>): string {
  return `otpauth://totp/${encodeURIComponent(`${item.title ?? ""}:${item.username ?? ""}`)}?secret=${encodeURIComponent(normalizeSecret(item.secret ?? ""))}&issuer=${encodeURIComponent(item.title ?? "")}&period=${item.period ?? 30}&algorithm=SHA1&digits=6`;
}
export function websites(value: string): string[] {
  return value.split(/[\s,;]+/).filter(Boolean).flatMap(part => {
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
