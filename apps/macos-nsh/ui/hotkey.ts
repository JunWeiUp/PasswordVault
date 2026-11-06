// Global Quick Access shortcut: choice kept in app storage (not the vault),
// registered natively; a press opens Quick Access while the vault is unlocked.
import { signal, Storage } from "nsh";
import { Hotkey } from "passwordvault/native";

export type ShortcutChoice = "command-shift-space" | "command-option-p" | "disabled";
export const SHORTCUT_LABEL: Record<ShortcutChoice, string> = {
  "command-shift-space": "⇧⌘Space",
  "command-option-p": "⌥⌘P",
  disabled: "关闭",
};
export const shortcut = signal<ShortcutChoice>("command-shift-space");
/** false when another app (e.g. the SwiftUI PasswordVault) already holds the shortcut. */
export const shortcutAvailable = signal(true);

export async function setShortcut(choice: ShortcutChoice) {
  shortcut.set(choice);
  await Storage.setItem("quickAccessShortcut", choice);
  shortcutAvailable.set(await Hotkey.configure(choice));
}

/** Starts the shortcut once for the app's lifetime. */
export async function startShortcut(onPress: () => void) {
  const saved = (await Storage.getItem("quickAccessShortcut")) as ShortcutChoice | null;
  await setShortcut(saved && saved in SHORTCUT_LABEL ? saved : "command-shift-space");
  setInterval(() => {
    if (Hotkey.poll()) onPress();
  }, 200);
}
