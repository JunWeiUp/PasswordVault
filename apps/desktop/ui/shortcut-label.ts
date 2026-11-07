import { platform } from "nsh";
/** Present the same mod-key bindings using each desktop's familiar key names. */
export function shortcutLabel(text: string): string {
  return platform.os === "macos" ? text : text
    .replaceAll("⇧⌘", "Ctrl+Shift+")
    .replaceAll("⌥⌘", "Ctrl+Alt+")
    .replaceAll("⌘", "Ctrl+")
    .replaceAll("⌥", "Alt+")
    .replaceAll("⇧", "Shift+");
}
