// Visual tokens from docs/design/macos-app/README.md, light and dark.
import { colorScheme, computed, signal } from "nsh";

const light = {
  blue: "#3265db",
  blueHover: "#2a57c2",
  primaryBg: "#3265db",
  primaryBgHover: "#2a57c2",
  blueSoft: "#e8eefb",
  blueLine: "#dce6fa",
  ink: "#242a35",
  ink2: "#4a5362",
  muted: "#5e6775",
  faint: "#6b7482",
  line: "#e6e8ec",
  line2: "#eff1f4",
  side: "#eff1f5",
  sideLine: "#dce0e6",
  list: "#fbfcfd",
  surface: "#ffffff",
  soft: "#f5f6f8",
  soft2: "#f8f9fb",
  field: "#edf0f4",
  green: "#217a52",
  greenSoft: "#eaf6f0",
  orange: "#a55c0c",
  orangeSoft: "#fdf3e6",
  red: "#c43333",
  dangerBg: "#c43333",
  redSoft: "#fdeeee",
  backdrop: "rgba(30,47,73,0.22)",
  onBlue: "#ffffff",
};

const dark: typeof light = {
  blue: "#6b97ff",
  blueHover: "#8ab0ff",
  primaryBg: "#3b6fe6",
  primaryBgHover: "#4c7ef0",
  blueSoft: "#243250",
  blueLine: "#30446c",
  ink: "#e8ebf1",
  ink2: "#c2c9d4",
  muted: "#97a0b0",
  faint: "#858e9e",
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
  orange: "#e8a958",
  orangeSoft: "#3a2d1a",
  red: "#f27c7c",
  dangerBg: "#c93b3b",
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
export const layout = { sidebar: 204, list: 296, toolbar: 52 };

/** Interface text scale (Settings → 通用 → 文字大小); 1.15 by default. */
export const TEXT_SCALES = [
  [1, "标准"],
  [1.15, "大"],
  [1.3, "特大"],
] as const;
export const textScale = signal(1.15);
/** A font size, line height or text-bound control height at the current text scale. */
export const fs = (n: number) => Math.round(n * textScale() * 2) / 2;
