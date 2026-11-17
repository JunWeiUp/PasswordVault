// Relay lifecycle, device groups and symmetric bidirectional sync.
import { Canvas, View, signal, effect } from "nsh";
import { pollEvery } from "../polling";
import { isMac } from "../native";
import { Relay } from "passwordvault/native";
import { Banner, Btn, Group, Row, T, confirm, closeSheet, openSheet, SheetTitle, SheetFooter } from "../kit";
import { call, errorText, load, refreshItems, phase, settings, onLock, vaultInstance } from "../store";
import { c } from "../theme";
import { GroupPanel } from "./GroupPanel";

type Summary = { enabled?: boolean; mode?: string; pending?: number; peers?: string[] | Record<string, unknown>; capabilities?: string[]; archivedConflicts?: number; skew?: boolean };
const summary = signal<Summary>({});
const roster = signal<any>({});
const peerState = signal<any>({});
const busy = signal(false);
const failure = signal("");
const syncBlocked = signal(false);
const connection = signal<any>({ transport: "disconnected", online: [] });
/** Symmetric sync: every member of the group syncs both ways; no primary, grants or conflict list. */
export const meshSync = () => !!roster().state && !roster().peerLibrary;
export const RELAY_UPGRADE_MESSAGE = "部分设备尚未验证格式兼容性，正在自动协商";
export function relayErrorText(error: unknown) {
  const text = String(error).replace(/^Error:\s*/, "");
  const messages: Record<string,string> = {
    RelayQrInvalid: "请选择只含一个有效设备组邀请二维码的图片。", RelayQrTooLarge: "二维码图片不能超过 20 MB。",
    DevicesSyncBlocked: RELAY_UPGRADE_MESSAGE, InvitationExpired: "邀请已过期，请生成新邀请。",
    ApprovalConflict: "设备组已变化，此次审批未完成；请刷新后重新核对。",
    ManagerRequired: "此操作需要设备组管理员。", VerificationCodeMismatch: "配对码不一致，请重新核对。",
    AnotherJoinPending: "已有待处理的入组申请，请先完成当前申请。", LegacyRelayResetRequired: "旧手动接入需要重新建组：请清除本机接入后重新创建或加入设备组。",
    GroupAccessRevoked: "本机设备组权限已被撤销。", PeerLibraryIdentityRequired: "对等库需要通过独立的身份回执授权。",
    RelayConnection: "暂时无法连接中继，改动保留在本机。", RelayHttp409: "设备组已被其他设备修改，请刷新后重试。",
    RelayIdentityChanged: "本机接入已变更，旧操作已取消。",
    RelayHttp401: "中继拒绝接入：请更新中继密码后重试；设备组身份已保留，自动重试已停止。若仍失败，请检查接入凭据。", RelayPasswordInvalid: "中继密码格式不正确：需 8–128 位，不能包含空格。", RelayHttp403: "中继拒绝此操作。", RelayHttp410: "邀请已失效或已取消。",
    RelayFileTooLarge: "本次数据超过预览版文件传输大小限制，改动保留在本机。",
  }; return messages[text] ?? errorText(error);
}
export function exitNotice(exit: { disband?: boolean; remote?: string }): string {
  if (exit.remote === "confirmed") return exit.disband ? "本机已退出，服务器已确认解散设备组" : "本机已退出，服务器已确认退出";
  if (exit.remote === "failed") return exit.disband ? "本机已退出，服务器解散未完成" : "本机已退出，服务器尚未确认退出";
  return exit.disband ? "本机已退出，正在尝试通知服务器解散设备组" : "本机已退出，正在尝试通知服务器";
}
let generation = 0;
export function relayOnLock() { if (!isMac) void Relay.disconnect(vaultInstance).catch(() => {}); connection.set({ transport: "disconnected", online: [] }); ++generation; summary.set({}); roster.set({}); peerState.set({}); syncBlocked.set(false); failure.set(""); closeSheet(); }
onLock(relayOnLock);
effect(() => {
  if (phase() !== "unlocked") { relayOnLock(); return; }
  if (!isMac) void Relay.connect(vaultInstance).catch((e) => { if (phase() === "unlocked") failure.set(relayErrorText(e)); });
  let updates = 0;
  const stop = pollEvery(1000, async (isActive) => {
    if (phase() !== "unlocked") return;
    const state = JSON.parse(await Relay.connectionStatus(vaultInstance));
    if (!isActive() || phase() !== "unlocked") return;
    connection.set(state);
    if (Number(state.updates ?? 0) !== updates) {
      updates = Number(state.updates ?? 0);
      void refreshItems().then(refreshRelay).catch(() => {});
    }
  });
  return () => { stop(); if (!isMac) void Relay.disconnect(vaultInstance).catch(() => {}); };
});
/** Safe sidebar accessor: membership never implies a live connection. */
export function syncStatus(): string {
  if (phase() !== "unlocked") return "已锁定 · 同步已断开";
  if (roster().state && connection().transport !== "connected") return ({ connecting: "正在连接中继…", reconnecting: "中继连接中断，正在重试…" } as Record<string,string>)[connection().transport] ?? "中继未连接 · 点击立即同步重连";
  if (meshSync()) return connection().transport === "connected" ? "已同步 · 组内设备自动双向同步" : "中继未连接";
  if (syncBlocked()) return RELAY_UPGRADE_MESSAGE;
  const count = Object.keys(peerState().conflicts ?? {}).length;
  if (count) return `${count} 项同步冲突`;
  return ({ connected: "设备组已连接", connecting: "正在连接设备组…", reconnecting: "等待重新连接…" } as Record<string,string>)[connection().transport] ?? "中继未连接";
}
export async function refreshRelay() {
  const epoch = ++generation;
  if (phase() !== "unlocked") { summary.set({}); roster.set({}); peerState.set({}); syncBlocked.set(false); return; }
  try {
    const [state, group, devices] = await Promise.all([call<Summary>({ op: "relay-status" }), Relay.summary(vaultInstance), call({ op: "devices-status" })]);
    const parsed = JSON.parse(group);
    const library = settings().activePeerLibrary || parsed.peerLibrary;
    const peer = library ? await call({ op: "relay-peer-status", library }) : {};
    if (epoch !== generation || phase() !== "unlocked") return;
    peerState.set(peer); summary.set(state); roster.set(parsed);
    // Peer libraries still cannot carry format-7 device records; personal groups can.
    syncBlocked.set(!!library && Number(devices.formatVersion) >= 7);
    failure.set("");
  } catch (e) { if (epoch === generation && phase() === "unlocked") failure.set(relayErrorText(e)); }
}
/** Only pass an already-created invitation link. Never logs the fragment key. */
export function InvitationQR(props: { link: string }) {
  const matrix = signal<boolean[][]>([]);
  effect(() => { try { matrix.set(JSON.parse(Relay.qr(props.link))); } catch { matrix.set([]); } });
  return <Canvas accessibilityLabel="设备组邀请二维码" style={{ width: 232, height: 232 }} draw={(cx, size) => {
    cx.fillStyle = "#ffffff"; cx.fillRect(0, 0, size.width, size.height);
    const rows = matrix(); if (!rows.length) return;
    const unit = Math.floor(Math.min(size.width, size.height) / rows.length);
    const ox = Math.floor((size.width - rows.length * unit) / 2), oy = Math.floor((size.height - rows.length * unit) / 2);
    cx.fillStyle = "#000000";
    rows.forEach((row, y) => row.forEach((dark, x) => { if (dark) cx.fillRect(ox + x * unit, oy + y * unit, unit, unit); }));
  }} />;
}
async function groupAction(request: Record<string, unknown>) {
  if (busy() || phase() !== "unlocked") throw new Error("Locked");
  busy.set(true); failure.set("");
  try { await Relay.action(vaultInstance, JSON.stringify(request)); if (phase() === "unlocked") { const status = JSON.parse(await Relay.connectionStatus(vaultInstance)); if (phase() === "unlocked") { connection.set(status); await refreshRelay(); } } }
  catch (e) { failure.set(relayErrorText(e)); await refreshRelay().catch(() => {}); failure.set(relayErrorText(e)); throw e; }
  finally { busy.set(false); }
}
function comparePeer(key: string, candidates: any[]) {
  const library = peerState().library;
  openSheet({ width: 640, render: (close) => <View style={{ gap: 12 }}>
    <SheetTitle title="比较对等库修改" text={key} />
    {candidates.map((candidate) => <Group style={{ gap: 8, paddingVertical: 10 }}>
      <T weight="600">{candidate.device || candidate.author || candidate.id}</T><T size={12}>{JSON.stringify(candidate.value, null, 2)}</T>
      <Btn label="使用此版本" disabled={busy() || syncBlocked() || peerState().frozen === true} onPress={() => {
        close(); confirm({ title: "解决此项冲突", text: "此版本将作为新的已解决版本同步给授权设备。", ok: "确认使用", onConfirm: async () => {
          busy.set(true); try { await call({ op: "relay-peer-resolve", library, key, value: candidate.value }); await load(); await refreshRelay(); }
          catch(e) { failure.set(relayErrorText(e)); } finally { busy.set(false); }
        } });
      }} />
    </Group>)}
    <SheetFooter><Btn label="关闭" onPress={close} /></SheetFooter>
  </View> });
}
export function RelayPage() {
  effect(() => { if (phase() === "unlocked") void refreshRelay(); else { ++generation; summary.set({}); roster.set({}); peerState.set({}); syncBlocked.set(false); failure.set(""); closeSheet(); } });
  return <View style={{ gap: 14 }}>
    <T size={19} weight="600">同步与设备</T>
    <If when={roster().state && meshSync()}>
      <Group>
        <T weight="600">{roster().state?.name || "我的密码库"}</T>
        <T size={12} color={c().muted}>组内所有设备自动双向同步。多台设备同时修改同一条时以较新的修改为准，较旧版本可在条目历史中找回。</T>
      </Group>
    </If>
    <If when={meshSync() && Number(summary().archivedConflicts ?? 0) > 0}><Banner tone="info" title={`升级时 ${summary().archivedConflicts} 个旧冲突版本已存入条目历史`}>无需再手动处理冲突；需要时可在对应条目的历史中恢复。</Banner></If>
    <If when={meshSync() && summary().skew === true}><Banner tone="warn" title="有设备的系统时间明显不准">同时修改时以时间较新的修改为准，请校准该设备时间。</Banner></If>
    <If when={syncBlocked()}><Banner tone="warn" title="对等库暂不支持设备条目同步">个人设备组不受影响。</Banner></If>
    <If when={!roster().state}><Banner tone="info" title="扫码加入，自动双向同步">创建设备组，或在其他设备上扫描邀请二维码加入。组内所有设备自动双向同步，无需逐台授权。</Banner></If>
    <Group><Row><View style={{ flex: 1 }}><T weight="600">{syncStatus()}</T></View><Btn label="刷新记录" disabled={busy()} onPress={() => void refreshRelay()} /><Btn label="立即同步" disabled={busy() || !roster().state} onPress={async () => { try { await Relay.syncNow(vaultInstance); } catch(e) { failure.set(relayErrorText(e)); } }} /></Row></Group>
    <If when={failure()}><Banner tone="err" title={failure()} /></If>
    <If when={connection().error}><Banner tone="warn" title={relayErrorText(connection().error)} /></If>
    <If when={connection().exit}><Banner tone={connection().exit?.remote === "failed" ? "warn" : "info"} title={exitNotice(connection().exit ?? {})}>本地资料已保留；退出后不会自动恢复旧组连接。</Banner></If>
    <If when={Object.keys(peerState().conflicts ?? {}).length > 0}>
      <T weight="600">对等库冲突</T>
      <Group>{Object.entries(peerState().conflicts ?? {}).map(([key, candidates]) => <Row style={{ paddingVertical: 10 }}><T style={{ flex: 1 }}>{key}</T><Btn label="比较修改" disabled={busy()} onPress={() => comparePeer(key, candidates as any[])} /></Row>)}</Group>
    </If>
    <T weight="600">设备组</T>
    <GroupPanel group={roster()} busy={busy()} act={groupAction} online={connection().online ?? []} />
    <If when={!roster().state?.members?.length}><T color={c().muted}>本地没有设备组记录</T></If>
  </View>;
}
