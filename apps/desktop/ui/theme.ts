// Visual tokens from docs/design/macos-app/README.md, light and dark.
import { colorScheme, computed, signal } from "nsh";

const light = {
  blue: "#3265db",
  blueHover: "#2a57c2",
  blueSoft: "#e8eefb",
  blueLine: "#dce6fa",
  ink: "#242a35",
  ink2: "#5c6573",
  muted: "#7b838f",
  faint: "#9aa1ab",
  line: "#e6e8ec",
  line2: "#eff1f4",
  side: "#eff1f5",
  sideLine: "#dce0e6",
  list: "#fbfcfd",
  surface: "#ffffff",
  soft: "#f5f6f8",
  soft2: "#f8f9fb",
  field: "#edf0f4",
  green: "#2f8f63",
  greenSoft: "#eaf6f0",
  orange: "#b86a12",
  orangeSoft: "#fdf3e6",
  red: "#cf3f3f",
  redSoft: "#fdeeee",
  backdrop: "rgba(30,47,73,0.22)",
  onBlue: "#ffffff",
};

const dark: typeof light = {
  blue: "#5b8cff",
  blueHover: "#7aa2ff",
  blueSoft: "#243250",
  blueLine: "#30446c",
  ink: "#e8ebf1",
  ink2: "#b9c0cc",
  muted: "#8d96a5",
  faint: "#6f7887",
  line: "#2d333e",
  line2: "#272c35",
  side: "#1a1e25",
  sideLine: "#2a2f38",
  list: "#1d2129",
  surface: "#21252d",
  soft: "#272c35",
  soft2: "#252a33",
  field: "#2b313b",
  green: "#57c18f",
  greenSoft: "#1c3529",
  orange: "#e3a04f",
  orangeSoft: "#3a2d1a",
  red: "#f07171",
  redSoft: "#3e2226",
  backdrop: "rgba(0,0,0,0.45)",
  onBlue: "#ffffff",
};

export type Colors = typeof light;
const current = computed(() => (colorScheme() === "dark" ? dark : light));

/** The current palette; read inside JSX or effects so it follows the appearance. */
export const c = (): Colors => current();

export const MONO = "Menlo";
export const radius = { control: 7, row: 9, card: 10, sheet: 14 };
export const layout = { sidebar: 236, list: 320, toolbar: 52 };

/** Interface text scale (Settings → 通用 → 文字大小); 1.15 by default. */
export const TEXT_SCALES = [
  [1, "标准"],
  [1.15, "大"],
  [1.3, "特大"],
] as const;
export const textScale = signal(1.15);
/** A font size, line height or text-bound control height at the current text scale. */
export const fs = (n: number) => Math.round(n * textScale() * 2) / 2;
