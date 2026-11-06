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
  "relay-peer-list",
  "relay-peer-status",
  "relay-peer-export",
  "peer-transport-status",
  "peer-transport-open",
  "peer-transport-seal",
  "relay-peer-status",
  "relay-peer-list",
  "relay-peer-export",
  "peer-transport-status",
  "peer-transport-open",
  "peer-transport-seal",
  "list",
  "draft-read",
  "structured-list",
  "structured-fill",
  "totp",
  "parse-totp",
  "generate",
  "passkey-index",
            "passkey-matches",
  "passkey-assert",
  "audit",
  "import-preview",
  "security-audit",
  "breach-request",
  "breach-response",
  "otp-matches",
  "otp-fill",
  "matches",
  "fill",
  "export",
  "export-plain",
  "share-options",
  "share-seal",
  "history-status",
  "history-list",
  "recovery-status",
  "recovery-generate",
  "recovery-export",
  "attachment-read",
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
  if (
    !["totp", "list", "matches"].includes(request.op) &&
    !request.op.startsWith("relay-peer-") &&
    !request.op.startsWith("peer-transport-")
  )
    lastActivity = Date.now();
  const before = checkpoint!;
  try {
    const result = JSON.parse(engine.command(JSON.stringify(request)));
    if (!readOnly.has(request.op)) {
      const next = engine.snapshot();
      await writeStorage(
        next,
        before,
        [
          "history-enable",
          "recovery-enable",
          "attachment-add",
          "import-commit",
          "passkey-create",
        ].includes(request.op) ||
          (request.op === "save" &&
            !!(
              (request.item as any)?.customFields ||
              ["creditCard", "identity"].includes((request.item as any)?.type)
            )),
      );
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

export function recoverStorage(
  before: string | undefined,
  after: string,
  key: Uint8Array,
): Promise<void> {
  const operation = queue.then(async () => {
    try {
      if (!locked()) throw new Error("already-unlocked");
      const epoch = generation;
      await wasm.default();
      if (before !== undefined) {
        const proof = new wasm.BrowserVault(before, key.slice());
        proof.free();
        if (
          JSON.parse(before).header.vaultId !== JSON.parse(after).header.vaultId
        )
          throw new Error("authentication");
      }
      const candidate = new wasm.BrowserVault(after, key.slice());
      candidate.free();
      if (epoch !== generation) throw new Error("locked");
      await writeStorage(after, before, true);
      if (epoch !== generation) throw new Error("locked");
      await unlock(after, key, false);
    } finally {
      key.fill(0);
    }
  });
  queue = operation.catch(() => {});
  return operation;
}
