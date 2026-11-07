import type { Item } from "../store";
export type DeviceService = { id: string; name: string; kind: "ssh" | "vnc" | "browser" | "custom"; remotePort: number; localPort: number; path: string };
export type DeviceCommand = { id: string; title: string; text: string; secret: boolean };
export type DeviceFile = { attachmentId: string; name: string; mime: string; size: number };
export type DeviceData = { version: 1; host: string; port: number; username: string; authMethod: "password" | "key" | "agent"; password: string; privateKey: string; aliases: string[]; notes: string; services: DeviceService[]; commands: DeviceCommand[]; files: DeviceFile[] };
export type DeviceDocument = { id: string; name: string; text: string; size: number };
export type DeviceImportGroup = { id: string; title: string; documents: DeviceDocument[] };
export function planDeviceImport(documents: DeviceDocument[], existing: Item[]): { groups: DeviceImportGroup[]; skipped: string[] } {
  const saved = existing.filter(i => i.type === "device" && !i.isDeleted).flatMap(i => i.device?.commands ?? []);
  const seen = new Set<string>(), skipped: string[] = [], groups = new Map<string, DeviceImportGroup>();
  for (const document of documents) {
    const source = JSON.stringify([document.name, document.text]);
    if (seen.has(source) || saved.some(c => c.id === document.id || (c.title === document.name && c.text === document.text))) {
      skipped.push(document.name); continue;
    }
    seen.add(source);
    const stem = document.name.replace(/\.[^.]+$/, "");
    const prefix = (stem.includes("-") ? stem.slice(0, stem.indexOf("-")) : stem).trim() || "未命名设备";
    if (!groups.has(prefix)) groups.set(prefix, { id: crypto.randomUUID(), title: prefix, documents: [] });
    groups.get(prefix)!.documents.push(document);
  }
  return { groups: [...groups.values()], skipped };
}
export function importedDevice(documents: DeviceDocument[]): DeviceData {
  // Shell syntax and node URLs are deliberately not interpreted as host settings.
  return { ...blankDevice(), commands: documents.map(d => ({ id: d.id, title: d.name, text: d.text, secret: true })) };
}
export const blankDevice = (): DeviceData => ({ version: 1, host: "", port: 22, username: "", authMethod: "password", password: "", privateKey: "", aliases: [], notes: "", services: [], commands: [], files: [] });
export const deviceSubtitle = (item: Item): string => `${item.device?.username ? `${item.device.username}@` : ""}${item.device?.host || `${item.device?.commands?.length ?? 0} 条资料`}${item.device?.host && item.device?.port ? `:${item.device.port}` : ""}`;
export const deviceSearchText = (item: Item): string => [item.title, item.device?.host, item.device?.username, ...(item.device?.aliases ?? []), ...(item.tags ?? []), ...(item.device?.services ?? []).map((s: DeviceService) => s.name)].filter(Boolean).join(" ").toLowerCase();
const quote = (value: string) => `'${value.replace(/'/g, `'"'"'`)}'`;
// Display/copy only; never pass this string to an execution API. Secrets are excluded.
export function connectionCommand(d: DeviceData, service?: DeviceService): string {
  const target = quote(`${d.username ? `${d.username}@` : ""}${d.host}`);
  const tunnel = service ? ` -N -L ${service.localPort}:127.0.0.1:${service.remotePort}` : "";
  return `ssh -p ${d.port}${tunnel} -- ${target}`;
}

export function documentKind(title: string): string {
  const ext = title.split(".").pop()?.toLowerCase() ?? "";
  return ({ py: "Python", pyw: "Python", sh: "Shell", bash: "Shell", zsh: "Shell", command: "Shell", js: "JavaScript", ts: "TypeScript", json: "JSON", yaml: "YAML", yml: "YAML", toml: "TOML", md: "Markdown", html: "HTML", css: "CSS", sql: "SQL", conf: "配置", ini: "配置" } as Record<string, string>)[ext] ?? "文本";
}
