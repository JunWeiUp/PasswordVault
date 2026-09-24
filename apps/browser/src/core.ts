import { readStorage, writeStorage } from "./storage";
import * as wasm from "../wasm/vault_core";
import type { BrowserVault } from "../wasm/vault_core";
export type Request = { op: string; [key: string]: unknown };
let engine: BrowserVault | undefined;
let generation = 0;
let lastActivity = 0;
let idleMinutes = 60;
let checkpoint: string | undefined;
let queue: Promise<unknown> = Promise.resolve();
const readOnly = new Set([
  "list",
  "totp",
  "parse-totp",
  "generate",
  "audit",
  "matches",
  "fill",
  "export",
  "export-plain",
]);
export function locked() {
  if (engine && Date.now() - lastActivity > idleMinutes * 60_000) lock();
  return !engine;
}
export function lock() {
  generation += 1;
  engine?.free();
  engine = undefined;
  checkpoint = undefined;
  lastActivity = 0;
}
export async function unlock(
  storage: string,
  key: Uint8Array,
  create: boolean,
) {
  await wasm.default();
  const candidate = new wasm.BrowserVault(storage, key);
  key.fill(0);
  try {
    if (create) {
      if (await readStorage()) throw new Error("already-exists");
      await writeStorage(storage, undefined);
    } else if ((await readStorage()) !== storage)
      throw new Error("stale-storage");
    lock();
    engine = candidate;
    checkpoint = storage;
    lastActivity = Date.now();
    const doc = JSON.parse(engine.command(JSON.stringify({ op: "list" })));
    idleMinutes = doc.settings.autoLockMinutes ?? 60;
  } catch (error) {
    candidate.free();
    throw error;
  }
}
async function execute(request: Request): Promise<any> {
  if (locked() || !engine) throw new Error("locked");
  if (request.op === "activity") {
    lastActivity = Date.now();
    return {};
  }
  if (request.op === "lock") {
    lock();
    return { ok: true };
  }
  const current = engine;
  const epoch = generation;
  // A different standalone Web tab may have committed a newer document. Never overwrite it.
  if ((await readStorage()) !== checkpoint) {
    lock();
    throw new Error("stale-storage");
  }
  if (generation !== epoch || engine !== current) throw new Error("locked");
  if (!["totp", "list", "matches"].includes(request.op)) lastActivity = Date.now();
  const before = checkpoint!;
  try {
    const result = JSON.parse(engine.command(JSON.stringify(request)));
    if (!readOnly.has(request.op)) {
      const next = engine.snapshot();
      await writeStorage(next, before);
      if (generation !== epoch || engine !== current) throw new Error("locked");
      checkpoint = next;
      if (request.op === "settings")
        idleMinutes =
          (request.settings as { autoLockMinutes?: number }).autoLockMinutes ??
          idleMinutes;
    }
    return result;
  } catch (error) {
    if (generation === epoch && engine === current)
      engine.restoreCheckpoint(before);
    throw error;
  }
}
export function command(request: Request): Promise<any> {
  const result = queue.then(() => execute(request));
  queue = result.catch(() => {});
  return result;
}
