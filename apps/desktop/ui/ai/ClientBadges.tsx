// Shared AI client signals, status pills, action buttons, and single-client actions.
import { signal, View } from "nsh";
import { Icon } from "../icons";
import { T, confirm } from "../kit";
import { onLock, toast } from "../store";
import { c, fs } from "../theme";
import { getUiPref, setUiPref } from "../api/extensions";
import {
  AI_CLIENT_NOTES_PREF_KEY,
  pruneClientNotes,
  type AiClientFilter,
  type AiClientState,
  type AiClientView,
} from "../api/aiClients";
import { change } from "./index";

export const clientFilter = signal<AiClientFilter>("all");
export const clientSearch = signal("");
export const expandedClientId = signal<string | null>(null);
export const auditClientId = signal<string | null>(null);

onLock(() => {
  clientFilter.set("all");
  clientSearch.set("");
  expandedClientId.set(null);
  auditClientId.set(null);
});

export function clientNotesMap(): Record<string, string> {
  const raw = getUiPref<Record<string, string>>(AI_CLIENT_NOTES_PREF_KEY, {});
  return raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
}

export async function saveClientNote(clientId: string, note: string): Promise<void> {
  const next = { ...clientNotesMap() };
  const clean = note.trim();
  if (clean) next[clientId] = clean;
  else delete next[clientId];
  await setUiPref(AI_CLIENT_NOTES_PREF_KEY, next);
}

export async function pruneNotesAfterRevoke(revokedIds: string[]): Promise<void> {
  const removed = new Set(revokedIds);
  const current = clientNotesMap();
  const kept = Object.keys(current).filter((id) => !removed.has(id));
  if (kept.length !== Object.keys(current).length) {
    await setUiPref(AI_CLIENT_NOTES_PREF_KEY, pruneClientNotes(current, kept));
  }
}

export function stateTone(state: AiClientState): "green" | "blue" | "orange" | "gray" {
  return ({ active: "green", idle: "blue", paused: "orange", unused: "gray" } as const)[state];
}

export function StatusDot(props: { state: AiClientState; size?: number }) {
  const size = () => props.size ?? 8;
  const unused = () => props.state === "unused";
  const color = () =>
    props.state === "active" ? c().green : props.state === "idle" ? c().blue : props.state === "paused" ? c().orange : c().faint;
  return (
    <View
      style={{
        width: size(),
        height: size(),
        borderRadius: size() / 2,
        backgroundColor: unused() ? "transparent" : color(),
        borderWidth: unused() ? 1.5 : 0,
        borderColor: unused() ? c().faint : "transparent",
        flexShrink: 0,
      }}
    />
  );
}

export function FingerprintChip(props: { fp: string; prefix?: string }) {
  return (
    <View
      tooltip="令牌短指纹（唯一标识，用于区分同名客户端）"
      style={{
        paddingHorizontal: 6,
        paddingVertical: 1,
        borderRadius: 5,
        backgroundColor: c().soft,
        borderWidth: 1,
        borderColor: c().line,
      }}
    >
      <T mono size={10.5} color={c().muted}>{`${props.prefix ?? "#"}${props.fp}`}</T>
    </View>
  );
}

export function Checkbox(props: { checked: boolean; label: string; onToggle: () => void }) {
  return (
    <View
      role="button"
      accessibilityLabel={props.label}
      accessibilityState={{ checked: props.checked }}
      onPress={props.onToggle}
      style={{
        width: 16,
        height: 16,
        borderRadius: 4,
        borderWidth: 1.5,
        borderColor: props.checked ? c().primaryBg : c().line,
        backgroundColor: props.checked ? c().primaryBg : c().surface,
        alignItems: "center",
        justifyContent: "center",
        cursor: "pointer",
        flexShrink: 0,
      }}
    >
      <If when={props.checked}>
        <Icon name="check" size={11} tint={c().onBlue} weight={2.4} />
      </If>
    </View>
  );
}

export function SoftActionBtn(props: { label: string; icon?: "pause" | "play" | "edit" | "history" | "trash"; tone?: "default" | "blue" | "orange" | "danger"; onPress: () => void; testID?: string; tooltip?: string }) {
  const tone = () => props.tone ?? "default";
  const bg = () =>
    ({ default: c().surface, blue: c().blueSoft, orange: c().orangeSoft, danger: c().surface })[tone()];
  const border = () =>
    ({ default: c().line, blue: c().blueLine, orange: c().orange, danger: c().line })[tone()];
  const fg = () =>
    ({ default: c().ink2, blue: c().blue, orange: c().orange, danger: c().red })[tone()];
  return (
    <View
      role="button"
      testID={props.testID}
      accessibilityLabel={props.label}
      tooltip={props.tooltip ?? props.label}
      onPress={props.onPress}
      style={{
        flexDirection: "row",
        alignItems: "center",
        gap: 4,
        paddingHorizontal: 8,
        height: fs(25),
        borderRadius: 6,
        borderWidth: 1,
        borderColor: border(),
        backgroundColor: bg(),
        cursor: "pointer",
      }}
      hoverStyle={{ backgroundColor: tone() === "danger" ? c().redSoft : c().blueSoft }}
    >
      <If when={props.icon}>
        <Icon name={props.icon!} size={12} tint={fg()} />
      </If>
      <T size={11.5} weight={tone() === "blue" ? "600" : "500"} color={fg()}>{props.label}</T>
    </View>
  );
}

export async function togglePauseClient(client: AiClientView): Promise<void> {
  const nextPaused = !client.paused;
  await change({ op: "set_paused", clientId: client.id, paused: nextPaused });
  toast(
    nextPaused
      ? `已暂停「${client.name}」(#${client.fingerprint})，令牌保留可随时恢复`
      : `已恢复「${client.name}」(#${client.fingerprint}) 的访问权限`,
  );
}

export function toggleAuditFilter(client: AiClientView): void {
  if (auditClientId() === client.id) {
    auditClientId.set(null);
    toast("已显示全部访问记录");
  } else {
    auditClientId.set(client.id);
    toast(`已筛选「${client.name}」(#${client.fingerprint}) 的访问记录`);
  }
}

export function revokeClientWithConfirm(client: AiClientView, onDone?: () => void): void {
  const label = `${client.name}${client.note ? `（${client.note}）` : ""} #${client.fingerprint}`;
  confirm({
    title: `撤销 ${label}？`,
    text: "该客户端的令牌立即失效，关联的免确认授权也会同时结束。已返回给 AI 的内容无法收回。",
    ok: "撤销客户端",
    danger: true,
    onConfirm: () => {
      void (async () => {
        await change({ op: "revoke", clientId: client.id });
        await pruneNotesAfterRevoke([client.id]);
        if (expandedClientId() === client.id) expandedClientId.set(null);
        if (auditClientId() === client.id) auditClientId.set(null);
        toast("已撤销客户端");
        onDone?.();
      })();
    },
  });
}

