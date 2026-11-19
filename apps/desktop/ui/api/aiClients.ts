// Pure TypeScript view-models, telemetry aggregation, duplicate detection, and
// filter/search helpers for paired AI clients.
// Notes are stored purely in encrypted `settings.uiPrefs.aiClientNotes` (no Rust schema needed).
import { AI_OPS, relativeAuditTime } from "./aiAccess";

export type AiClientState = "active" | "idle" | "paused" | "unused";
export type AiClientFilter = "all" | "active" | "paused" | "unused";

export interface RawAiClient {
  id: string;
  name?: string;
  fingerprint?: string;
  paused?: boolean;
  createdUnix?: number;
  lastUsedUnix?: number;
  callCount?: number;
  lastOp?: string;
}

export interface RawAiAuditRow {
  client?: string;
  item?: string;
  operation?: string;
  result?: string;
  unixSeconds?: number;
}

export interface RawAiLease {
  client?: string;
  entryId?: string;
  field?: string;
  reveal?: boolean;
  secondsLeft?: number | null;
}

export interface AiClientView {
  id: string;
  name: string;
  note: string;
  fingerprint: string;
  state: AiClientState;
  filterKey: "active" | "paused" | "unused";
  paused: boolean;
  createdUnix: number | null;
  lastUsedUnix: number | null;
  calls24h: number;
  callsTotal: number;
  lastOpLabel: string;
  hasLease: boolean;
}

export interface AiClientCounts {
  total: number;
  active: number;
  paused: number;
  unused: number;
}

export const AI_CLIENT_NOTES_PREF_KEY = "aiClientNotes";

export function fallbackFingerprint(id: string): string {
  const clean = String(id ?? "").replace(/[^a-zA-Z0-9]/g, "").toLowerCase();
  if (clean.length >= 8) return `${clean.slice(0, 4)}…${clean.slice(-4)}`;
  return clean || "0000";
}

export function formatPairedTime(unixSec: number | null): string {
  if (!unixSec || unixSec <= 0) return "早期配对";
  const d = new Date(unixSec * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function formatClientOp(op?: string): string {
  if (!op) return "尚未收到请求";
  const label = AI_OPS[op];
  return label ? `${label}（${op}）` : op;
}

export function buildAiClientViews(
  rawClients: RawAiClient[],
  auditRows: RawAiAuditRow[],
  leases: RawAiLease[],
  notesMap: Record<string, string> = {},
  nowSec: number = Math.floor(Date.now() / 1000),
): AiClientView[] {
  const cutoff24h = nowSec - 86400;
  const leaseClients = new Set((leases ?? []).map((l) => String(l.client ?? "")));

  const auditStats = new Map<string, { total: number; calls24h: number; lastUnix: number; lastOp: string; earliestUnix: number }>();
  for (const row of auditRows ?? []) {
    const cid = String(row.client ?? "");
    if (!cid || cid === "app" || cid === "unknown") continue;
    if (row.operation === "unlock" || row.result === "ClientPaused") continue;
    const ts = Number(row.unixSeconds ?? 0);
    const prev = auditStats.get(cid) ?? { total: 0, calls24h: 0, lastUnix: 0, lastOp: "", earliestUnix: 0 };
    prev.total += 1;
    if (ts >= cutoff24h) prev.calls24h += 1;
    if (ts > prev.lastUnix) {
      prev.lastUnix = ts;
      prev.lastOp = String(row.operation ?? "");
    }
    if (ts > 0 && (prev.earliestUnix === 0 || ts < prev.earliestUnix)) {
      prev.earliestUnix = ts;
    }
    auditStats.set(cid, prev);
  }

  const orderRank: Record<AiClientState, number> = { active: 0, idle: 1, paused: 2, unused: 3 };

  const views: AiClientView[] = (rawClients ?? []).map((raw) => {
    const id = String(raw.id ?? "");
    const name = String(raw.name ?? "").trim() || "本机 AI 客户端";
    const note = String(notesMap?.[id] ?? "").trim();
    const fingerprint = raw.fingerprint ? String(raw.fingerprint) : fallbackFingerprint(id);
    const paused = raw.paused === true;
    const stats = auditStats.get(id);
    const callsTotal = Math.max(Number(raw.callCount ?? 0), stats?.total ?? 0);
    const calls24h = stats?.calls24h ?? (Number(raw.lastUsedUnix ?? 0) >= cutoff24h && callsTotal > 0 ? 1 : 0);
    const lastUsedRaw = Math.max(Number(raw.lastUsedUnix ?? 0), stats?.lastUnix ?? 0);
    const lastUsedUnix = lastUsedRaw > 0 ? lastUsedRaw : null;
    const createdUnix = Number(raw.createdUnix ?? 0) > 0 ? Number(raw.createdUnix) : null;
    const lastOpCode = String(raw.lastOp || stats?.lastOp || "");

    let state: AiClientState;
    if (paused) state = "paused";
    else if (callsTotal <= 0 && !lastUsedUnix) state = "unused";
    else if (lastUsedUnix && lastUsedUnix >= cutoff24h) state = "active";
    else state = "idle";

    const filterKey: "active" | "paused" | "unused" =
      state === "paused" ? "paused" : state === "unused" ? "unused" : "active";

    return {
      id,
      name,
      note,
      fingerprint,
      state,
      filterKey,
      paused,
      createdUnix,
      lastUsedUnix,
      calls24h,
      callsTotal,
      lastOpLabel: callsTotal > 0 || lastOpCode ? formatClientOp(lastOpCode) : "尚未收到请求",
      hasLease: leaseClients.has(id),
    };
  });

  return views.sort((a, b) => {
    const r = orderRank[a.state] - orderRank[b.state];
    if (r !== 0) return r;
    const tu = (b.lastUsedUnix ?? 0) - (a.lastUsedUnix ?? 0);
    if (tu !== 0) return tu;
    const tc = (b.createdUnix ?? 0) - (a.createdUnix ?? 0);
    if (tc !== 0) return tc;
    return a.name.localeCompare(b.name, "zh-Hans-CN");
  });
}

export function countAiClientStates(views: AiClientView[]): AiClientCounts {
  let active = 0, paused = 0, unused = 0;
  for (const v of views) {
    if (v.filterKey === "active") active += 1;
    else if (v.filterKey === "paused") paused += 1;
    else unused += 1;
  }
  return { total: views.length, active, paused, unused };
}

export function findDuplicateClientNames(views: AiClientView[]): Array<[string, number]> {
  const counts = new Map<string, number>();
  for (const v of views) counts.set(v.name, (counts.get(v.name) ?? 0) + 1);
  return [...counts.entries()].filter(([, n]) => n > 1);
}

export function filterAiClients(
  views: AiClientView[],
  filter: AiClientFilter,
  search: string,
): AiClientView[] {
  const q = search.trim().toLowerCase();
  return views.filter((v) => {
    if (filter !== "all" && v.filterKey !== filter) return false;
    if (!q) return true;
    const hay = `${v.name} ${v.note} ${v.fingerprint} ${v.lastOpLabel}`.toLowerCase();
    return hay.includes(q);
  });
}

export function clientStateLabel(state: AiClientState): string {
  return ({ active: "活跃", idle: "空闲", paused: "已暂停", unused: "未使用" })[state];
}

export function clientSubline(v: AiClientView): string {
  const paired = formatPairedTime(v.createdUnix);
  if (v.paused) {
    const last = v.lastUsedUnix ? `上次活跃 ${relativeAuditTime(v.lastUsedUnix)} · 共 ${v.callsTotal} 次` : "从未调用";
    return `配于 ${paired} · 已暂停访问（保留令牌） · ${last}`;
  }
  if (v.callsTotal > 0 || v.lastUsedUnix) {
    const last = v.lastUsedUnix ? relativeAuditTime(v.lastUsedUnix) : "近期";
    return `配于 ${paired} · 最近活跃 ${last} · 近 24h ${v.calls24h} 次 / 共 ${v.callsTotal} 次`;
  }
  return `配于 ${paired} · 从未调用 · 建议核对或清理`;
}

export function pruneClientNotes(
  notesMap: Record<string, string>,
  liveClientIds: Iterable<string>,
): Record<string, string> {
  const live = new Set(liveClientIds);
  const next: Record<string, string> = {};
  for (const [k, v] of Object.entries(notesMap ?? {})) {
    const clean = String(v ?? "").trim();
    if (clean && live.has(k)) next[k] = clean;
  }
  return next;
}
