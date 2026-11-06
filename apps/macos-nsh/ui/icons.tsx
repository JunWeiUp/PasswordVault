// Line icons drawn on a 24×24 grid with Path2D (the same shapes as the design file).
import { Canvas, Path2D } from "nsh";

const circle = (x: number, y: number, r: number) => `M${x - r} ${y}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0`;
const rect = (x: number, y: number, w: number, h: number, r = 0) =>
  r
    ? `M${x + r} ${y}h${w - 2 * r}a${r} ${r} 0 0 1 ${r} ${r}v${h - 2 * r}a${r} ${r} 0 0 1 ${-r} ${r}h${-(w - 2 * r)}a${r} ${r} 0 0 1 ${-r} ${-r}v${-(h - 2 * r)}a${r} ${r} 0 0 1 ${r} ${-r}z`
    : `M${x} ${y}h${w}v${h}h${-w}z`;

const paths = {
  grid: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
  key: circle(7.5, 15.5, 4.5) + "M10.7 12.3 20 3m-4 4 3 3m-5-1 2 2",
  clock: circle(12, 13, 8) + "M12 9v4l2.5 2M9 2h6",
  wallet: rect(3, 5, 18, 14, 2) + "M3 10h18M7 15h3",
  id: rect(3, 5, 18, 14, 2) + circle(9, 11, 2) + "M6 16a3 3 0 0 1 6 0M14 10h4M14 14h3",
  coin: circle(12, 12, 9) + "M9 8h4.5a2 2 0 0 1 0 4H9h5a2 2 0 0 1 0 4H9zM11 6v2M11 16v2",
  note: "M6 3h9l4 4v14H6zM14 3v5h5M9 13h7M9 17h5",
  server: rect(3, 4, 18, 7, 2) + rect(3, 13, 18, 7, 2) + "M7 7.5h.01M7 16.5h.01",
  star: "M12 3l2.8 5.7 6.2.9-4.5 4.4 1 6.2L12 17.3l-5.5 2.9 1-6.2L3 9.6l6.2-.9z",
  trash: "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
  gear: "M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1" + circle(15, 6, 2) + circle(9, 12, 2) + circle(17, 18, 2),
  lock: rect(5, 11, 14, 10, 2) + "M8 11V7a4 4 0 0 1 8 0v4",
  search: circle(11, 11, 7) + "M20 20l-4-4",
  plus: "M12 5v14M5 12h14",
  minus: "M5 12h14",
  copy: rect(9, 9, 11, 11, 2) + "M5 15V5a1 1 0 0 1 1-1h9",
  eye: "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z" + circle(12, 12, 3),
  globe: circle(12, 12, 9) + "M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18",
  wand: "M15 4V2M15 10V8M11 6h2M17 6h2M4 20 14 10",
  shield: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9 12l2 2 4-4",
  sync: "M4 12a8 8 0 0 1 14-5.3L20 9M20 4v5h-5M20 12a8 8 0 0 1-14 5.3L4 15M4 20v-5h5",
  folder: "M3 6h6l2 2h10v11H3z",
  chev: "M9 6l6 6-6 6",
  chevd: "M6 9l6 6 6-6",
  back: "M15 6l-6 6 6 6",
  more: circle(6, 12, 1.3) + circle(12, 12, 1.3) + circle(18, 12, 1.3),
  finger: "M12 11v4M8.5 19.5A10 10 0 0 0 10 14v-2a2 2 0 0 1 4 0v1M6 16v-4a6 6 0 0 1 12 0v2M16 19a14 14 0 0 0 .7-3M3.5 9A9 9 0 0 1 20.5 9",
  cloud: "M7 18h10a4 4 0 0 0 .5-8 6 6 0 0 0-11.5 1.5A3.3 3.3 0 0 0 7 18z",
  browser: rect(3, 4, 18, 16, 2) + "M3 9h18M6 6.5h.01M9 6.5h.01",
  spark: "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16v4M17 18h4",
  down: "M12 4v11M7 10l5 5 5-5M5 20h14",
  up: "M12 20V9M7 14l5-5 5 5M5 4h14",
  history: "M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5M12 7v5l3 2",
  edit: "M4 20h4L19 9l-4-4L4 16zM14 6l4 4",
  check: "M5 12l5 5 9-10",
  x: "M6 6l12 12M18 6 6 18",
  alert: "M12 3 2 20h20zM12 10v4M12 17h.01",
  info: circle(12, 12, 9) + "M12 11v5M12 8h.01",
  phone: rect(7, 2, 10, 20, 2) + "M11 18h2",
  laptop: rect(4, 5, 16, 11, 1.5) + "M2 19h20",
  link: "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
  home: "M3 11l9-7 9 7M5 10v10h14V10",
  user: circle(12, 8, 4) + "M4 21a8 8 0 0 1 16 0",
  tools: "M15 6a4 4 0 0 0 4.5 5.2L12 18.7a2.1 2.1 0 0 1-3-3l7.5-7.5A4 4 0 0 1 15 6z",
  pin: "M9 3h6l-1 6 4 4H6l4-4zM12 13v8",
  bolt: "M13 2 4 14h7l-1 8 9-12h-7z",
  qr: rect(3, 3, 7, 7) + rect(14, 3, 7, 7) + rect(3, 14, 7, 7) + "M14 14h3v3h-3zM20 14v.01M17 20h4M20 17v.01",
  archive: rect(3, 4, 18, 5, 1) + "M5 9v11h14V9M10 13h4",
  passkey: circle(9, 8, 4) + "M3 20a6 6 0 0 1 9.5-4.9M17 12a2.5 2.5 0 1 0 0 5v4l1.5-1 1.5 1v-4",
  paper: "M14 3H6v18h12V7zM14 3v4h4",
} as const;

export type IconName = keyof typeof paths;
const cache = new Map<string, Path2D>();
const path = (name: IconName) => {
  let p = cache.get(name);
  if (!p) cache.set(name, (p = new Path2D(paths[name])));
  return p;
};

/** A stroked line icon; `fill` fills the shape too (a selected star). */
export function Icon(props: { name: IconName; size?: number; tint: string; fill?: boolean; weight?: number }) {
  const size = () => props.size ?? 16;
  return (
    <Canvas
      accessibilityElementsHidden
      style={{ pointerEvents: "none", width: size(), height: size() }}
      draw={(cx, { width }) => {
        cx.scale(width / 24, width / 24);
        cx.strokeStyle = props.tint;
        cx.fillStyle = props.tint;
        cx.lineWidth = props.weight ?? 1.7;
        cx.lineCap = "round";
        cx.lineJoin = "round";
        if (props.fill) cx.fill(path(props.name));
        cx.stroke(path(props.name));
      }}
    />
  );
}
