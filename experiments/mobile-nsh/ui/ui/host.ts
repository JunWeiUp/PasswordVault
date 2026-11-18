// The embedding iOS/Android app is the only data source. Secrets stay native: the host
// returns display data (codes are computed natively) and performs copies itself, so the
// clipboard gets the platform's local-only and expiry protections.
import { host } from "nsh";

export type CodeRow = { id: string; title: string; username: string; code: string; period: number; remaining: number };

export async function codes(): Promise<CodeRow[]> {
  const result = (await host.call("vault.codes")) as { codes?: CodeRow[] } | null;
  return Array.isArray(result?.codes) ? result!.codes : [];
}

export function copy(text: string, label: string): Promise<unknown> {
  return host.call("clipboard.copy", { text, label });
}

/** Opens the native detail page for an item until that page moves to NSH too. */
export function openItem(id: string): Promise<unknown> {
  return host.call("vault.open", { id });
}
