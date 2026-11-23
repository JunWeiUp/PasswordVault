// Pure helpers for the Obsidian-style personal knowledge base: hierarchical categories,
// canonical Markdown conversion, wikilinks/backlinks, AI writable policy and LCS line diff.
import { noteMarkdownNative } from "../api/nativeBridge";
import type { Item } from "../store";

export type NoteProperty = { key: string; value: string };
export type DiffLine = { type: "ctx" | "add" | "del"; text: string; lineNo: number };
export type CatNode = { path: string; leaf: string; depth: number; hasChildren: boolean };

export function catMatches(category: string | undefined, prefix: string | null | undefined): boolean {
  if (!prefix) return true;
  if (!category) return false;
  return category === prefix || category.startsWith(`${prefix}/`);
}

export function catLeaf(path: string | undefined | null): string {
  if (!path) return "未分类";
  const parts = path.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? path;
}

export function buildCatTree(categories: readonly string[], folded: Record<string, boolean>): CatNode[] {
  const unique = [...new Set(categories.map((c) => c.trim().replace(/^\/+|\/+$/g, "")).filter(Boolean))];
  const all = new Set<string>();
  for (const cat of unique) {
    let prefix = "";
    for (const seg of cat.split("/").filter(Boolean)) {
      prefix = prefix ? `${prefix}/${seg}` : seg;
      all.add(prefix);
    }
  }
  const sorted = [...all].sort((a, b) => a.localeCompare(b, "zh-Hans-CN"));
  const childrenOf = (parent: string) =>
    sorted.filter((c) =>
      parent === ""
        ? !c.includes("/")
        : c.startsWith(`${parent}/`) && !c.slice(parent.length + 1).includes("/"),
    );
  const out: CatNode[] = [];
  const walk = (parent: string, depth: number) => {
    for (const path of childrenOf(parent)) {
      const kids = childrenOf(path);
      out.push({ path, leaf: catLeaf(path), depth, hasChildren: kids.length > 0 });
      if (kids.length > 0 && !folded[path]) walk(path, depth + 1);
    }
  };
  walk("", 0);
  return out;
}

export function isAiWritableCategory(category: string | undefined, vaultSettings: Record<string, any>): boolean {
  if (
    !category ||
    vaultSettings?.aiAccessEnabled !== true ||
    vaultSettings?.aiAccessScopes?.notes !== true ||
    vaultSettings?.aiAccessNoteAutoWrite !== true
  ) {
    return false;
  }
  const prefixes: string[] = Array.isArray(vaultSettings?.aiAccessNoteWritableCategories)
    ? vaultSettings.aiAccessNoteWritableCategories
    : [];
  return prefixes.some((p) => catMatches(category, String(p).trim().replace(/^\/+|\/+$/g, "")));
}

export function isAiActor(actor: unknown): boolean {
  return typeof actor === "string" && actor.trim().startsWith("AI");
}

export function noteToMarkdown(item: Record<string, any>): string {
  if (item.noteFormat === "rich-v1" && item.noteDocument?.type === "doc") {
    try {
      const readable = noteMarkdownNative.toReadableMarkdown;
      if (typeof readable === "function") {
        const md = readable(JSON.stringify(item.noteDocument));
        if (typeof md === "string") return md;
      }
    } catch {}
    try {
      const res = JSON.parse(noteMarkdownNative.toMarkdown(JSON.stringify(item.noteDocument)));
      if (typeof res.markdown === "string") return res.markdown;
    } catch {}
  }
  return String(item.note ?? "");
}

export type PropDiffRow = {
  key: string;
  before: string;
  after: string;
  kind: "added" | "removed" | "changed" | "same";
};

export function diffNoteProperties(
  oldProps: readonly NoteProperty[] | undefined,
  newProps: readonly NoteProperty[] | undefined,
): PropDiffRow[] {
  const oldMap = new Map<string, string>();
  const newMap = new Map<string, string>();
  const order: string[] = [];
  for (const p of oldProps ?? []) {
    if (!p?.key) continue;
    oldMap.set(p.key, String(p.value ?? ""));
    if (!order.includes(p.key)) order.push(p.key);
  }
  for (const p of newProps ?? []) {
    if (!p?.key) continue;
    newMap.set(p.key, String(p.value ?? ""));
    if (!order.includes(p.key)) order.push(p.key);
  }
  return order.map((key) => {
    const hasOld = oldMap.has(key);
    const hasNew = newMap.has(key);
    const before = oldMap.get(key) ?? "";
    const after = newMap.get(key) ?? "";
    const kind = !hasOld ? "added" : !hasNew ? "removed" : before !== after ? "changed" : "same";
    return { key, before, after, kind };
  });
}

export function extractWikilinks(text: string): string[] {
  const out: string[] = [];
  const re = /\[\[([^\[\]\n]{1,120})\]\]/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const title = m[1].trim();
    if (title && !out.includes(title)) out.push(title);
  }
  return out;
}

export function findNoteBacklinks(target: Item, allItems: readonly Item[]): { item: Item; snippet: string }[] {
  if (target.type !== "secureNote" || !target.title?.trim()) return [];
  const needle = `[[${target.title.trim()}]]`;
  const results: { item: Item; snippet: string }[] = [];
  for (const item of allItems) {
    if (item.type !== "secureNote" || item.isDeleted || item.id === target.id) continue;
    const text = String(item.note ?? "");
    const searchExtra = String(item.__noteSearchText ?? "");
    if (!text.includes(needle) && !searchExtra.includes(needle)) continue;
    const line = text.split("\n").find((l) => l.includes(needle)) ?? text.slice(0, 100);
    results.push({ item, snippet: line.replace(/^[-*>\s#]+/, "").trim() });
  }
  return results;
}

export function diffLines(oldText: string, newText: string): DiffLine[] {
  const a = oldText ? oldText.split("\n") : [];
  const b = newText ? newText.split("\n") : [];
  const m = a.length, n = b.length;
  // Cap DP size for very large notes so UI stays instant.
  if (m * n > 250_000) {
    return [
      ...a.map((text, idx) => ({ type: "del" as const, text, lineNo: idx + 1 })),
      ...b.map((text, idx) => ({ type: "add" as const, text, lineNo: idx + 1 })),
    ];
  }
  const dp: Uint32Array[] = Array.from({ length: m + 1 }, () => new Uint32Array(n + 1));
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out: DiffLine[] = [];
  let i = 0, j = 0, oa = 1, nb = 1;
  while (i < m && j < n) {
    if (a[i] === b[j]) {
      out.push({ type: "ctx", text: b[j], lineNo: nb++ });
      oa++; i++; j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.push({ type: "del", text: a[i], lineNo: oa++ });
      i++;
    } else {
      out.push({ type: "add", text: b[j], lineNo: nb++ });
      j++;
    }
  }
  while (i < m) out.push({ type: "del", text: a[i++], lineNo: oa++ });
  while (j < n) out.push({ type: "add", text: b[j++], lineNo: nb++ });
  return out;
}

export function diffStats(oldText: string, newText: string): { add: number; del: number } {
  const lines = diffLines(oldText, newText);
  let add = 0, del = 0;
  for (const l of lines) {
    if (l.type === "add") add++;
    else if (l.type === "del") del++;
  }
  return { add, del };
}
