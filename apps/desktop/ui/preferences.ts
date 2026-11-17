// Device-local display preferences (not synced, never stored in the vault).
import { signal, Storage } from "nsh";

export type SortMode = "updated" | "title" | "created";
export const SORT_LABEL: Record<SortMode, string> = { updated: "最近修改", title: "名称 A–Z", created: "创建时间" };

/** Seconds before a copied secret is cleared from the clipboard; 0 never clears. */
export const CLIPBOARD_CHOICES: [number, string][] = [[15, "15 秒"], [30, "30 秒"], [60, "1 分钟"], [120, "2 分钟"], [0, "不自动清除"]];
export const clipboardSeconds = signal(30);
export const sortMode = signal<SortMode>("updated");
/** Show PasswordVault in the menu bar (macOS) or notification area (Windows). */
export const trayIcon = signal(false);
/** Keep app windows out of screenshots, recordings and screen sharing. */
export const hideFromCapture = signal(false);

export function setClipboardSeconds(value: number) {
  if (!CLIPBOARD_CHOICES.some(([v]) => v === value)) return;
  clipboardSeconds.set(value);
  void Storage.setItem("clipboardSeconds", String(value));
}
export function setSortMode(value: SortMode) {
  if (!(value in SORT_LABEL)) return;
  sortMode.set(value);
  void Storage.setItem("sortMode", value);
}
export function setTrayIcon(on: boolean) {
  trayIcon.set(on);
  void Storage.setItem("trayIcon", on ? "1" : "0");
}

export function setHideFromCapture(on: boolean) {
  hideFromCapture.set(on);
  void Storage.setItem("hideFromCapture", on ? "1" : "0");
}

export async function loadPreferences() {
  const [seconds, sort, tray, capture] = await Promise.all([
    Storage.getItem("clipboardSeconds"), Storage.getItem("sortMode"), Storage.getItem("trayIcon"), Storage.getItem("hideFromCapture"),
  ]);
  const n = Number(seconds);
  if (seconds !== null && CLIPBOARD_CHOICES.some(([v]) => v === n)) clipboardSeconds.set(n);
  if (sort && sort in SORT_LABEL) sortMode.set(sort as SortMode);
  trayIcon.set(tray === "1");
  hideFromCapture.set(capture === "1");
}
