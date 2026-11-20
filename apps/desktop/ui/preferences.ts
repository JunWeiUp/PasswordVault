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
/** Item list row spacing. */
export type ListDensity = "standard" | "compact";
export const DENSITY_LABEL: Record<ListDensity, string> = { standard: "标准", compact: "紧凑" };
export const listDensity = signal<ListDensity>("standard");
/** Close Quick Access after copying from it (default on). */
export const quickCloseAfterCopy = signal(true);
/** Show line numbers in the note rich editor and Markdown source pane (default on). */
export const noteLineNumbers = signal(true);
/** Vertical padding of an item list row for a density. */
export const rowPadding = (density: ListDensity) => (density === "compact" ? 5 : 10);

export function setListDensity(value: ListDensity) {
  if (!(value in DENSITY_LABEL)) return;
  listDensity.set(value);
  void Storage.setItem("listDensity", value);
}
export function setQuickCloseAfterCopy(on: boolean) {
  quickCloseAfterCopy.set(on);
  void Storage.setItem("quickCloseAfterCopy", on ? "1" : "0");
}
export function setNoteLineNumbers(on: boolean) {
  noteLineNumbers.set(on);
  void Storage.setItem("noteLineNumbers", on ? "1" : "0");
}

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
  const [seconds, sort, tray, capture, density, quickClose, lineNumbers] = await Promise.all([
    Storage.getItem("clipboardSeconds"), Storage.getItem("sortMode"), Storage.getItem("trayIcon"), Storage.getItem("hideFromCapture"),
    Storage.getItem("listDensity"), Storage.getItem("quickCloseAfterCopy"), Storage.getItem("noteLineNumbers"),
  ]);
  const n = Number(seconds);
  if (seconds !== null && CLIPBOARD_CHOICES.some(([v]) => v === n)) clipboardSeconds.set(n);
  if (sort && sort in SORT_LABEL) sortMode.set(sort as SortMode);
  trayIcon.set(tray === "1");
  hideFromCapture.set(capture === "1");
  if (density && density in DENSITY_LABEL) listDensity.set(density as ListDensity);
  quickCloseAfterCopy.set(quickClose !== "0");
  noteLineNumbers.set(lineNumbers !== "0");
}
