// User-started Have I Been Pwned check. Only a 5-character SHA-1 prefix leaves the
// device (`breach-request` + `vault_core::breach_range`); the padded response is matched locally.
// Results live in memory for this session and are cleared on lock.
import { signal } from "nsh";
import { Breach } from "passwordvault/native";
import { call, items, onLock, type Item } from "./store";

export type BreachResult = { exposed: number } | { failed: true };
export const breachResults = signal<Record<string, BreachResult>>({});
export const breachProgress = signal<{ done: number; total: number } | null>(null);
let generation = 0;

function passwordsOf(item: Item): string[] {
  const all = [item.password, ...(Array.isArray(item.accounts) ? item.accounts.map((a: any) => a?.password) : [])];
  return [...new Set(all.filter((p): p is string => typeof p === "string" && p.length > 0))];
}

export const checkable = () => items().filter((i) => i.type === "password" && !i.isDeleted && passwordsOf(i).length > 0);

async function exposures(password: string): Promise<number> {
  const { prefix, suffix } = await call({ op: "breach-request", password });
  const response = await Breach.range(prefix);
  const { count } = await call({ op: "breach-response", suffix, response });
  return count;
}

export async function startBreachCheck() {
  const run = ++generation;
  const targets = checkable();
  breachResults.set({});
  breachProgress.set({ done: 0, total: targets.length });
  for (const [index, item] of targets.entries()) {
    if (run !== generation) return;
    let result: BreachResult;
    try {
      let exposed = 0;
      for (const password of passwordsOf(item)) exposed += await exposures(password);
      result = { exposed };
    } catch {
      result = { failed: true };
    }
    if (run !== generation) return;
    breachResults.update((r) => ({ ...r, [item.id]: result }));
    breachProgress.set({ done: index + 1, total: targets.length });
  }
  if (run === generation) breachProgress.set(null);
}

export function stopBreachCheck() {
  generation++;
  breachProgress.set(null);
}

onLock(() => {
  stopBreachCheck();
  breachResults.set({});
});
