// Colored initial tiles for records: a stable tone per title.
export const TILE_TONES = 7;
export function tileFor(title: string | undefined): { initial: string; tone: number } {
  const text = (title ?? "").trim();
  const first = [...text][0];
  let hash = 0;
  for (const ch of text) hash = (Math.imul(hash, 31) + ch.codePointAt(0)!) >>> 0;
  return { initial: first ? first.toLocaleUpperCase() : "?", tone: hash % TILE_TONES };
}
