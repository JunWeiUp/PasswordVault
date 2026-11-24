// Relay lifecycle, device groups and symmetric bidirectional sync.
import { Canvas, View, signal, effect } from "nsh";
import { pollEvery } from "../polling";
import { isMac } from "../native";
import { Relay } from "passwordvault/native";
import { Banner, Btn, Group, Pill, Row, T, confirm, closeSheet, openSheet, SheetTitle, SheetFooter } from "../kit";
import { coreApi, errorText, load, meshConflicts, refreshItems, refreshMeshConflicts, phase, settings, onLock, vaultInstance } from "../store";
import type { RelaySummary } from "../api/core";
import { c } from "../theme";
import { GroupPanel } from "./GroupPanel";
import { openConflictResolver } from "../history/ConflictResolverSheet";
import { bumpNoteAssets } from "../api/noteAssets";

type Summary = RelaySummary;
const summary = signal<Summary>({});
const roster = signal<any>({});
const acting = signal(false);
const refreshing = signal(false);
const syncing = signal(false);
const failure = signal("");
const connection = signal<any>({ transport: "disconnected", online: [] });
/** Symmetric sync: every member of the group syncs both ways; no primary, grants or conflict list. */
export const meshSync = () => !!roster().state;
export const isRelayOffline = () => phase() === "unlocked" && !!roster().state && connection().transport !== "connected";
export const RELAY_UPGRADE_MESSAGE = "部分设备尚未验证格式兼容性，正在自动协商";
export function relayErrorText(error: unknown) {
  const text = String(error).replace(/^Error:\s*/, "");
  const messages: Record<string,string> = {
    RelayQrInvalid: "请选择只含一个有效设备组邀请二维码的图片。", RelayQrTooLarge: "二维码图片不能超过 20 MB。",
    DevicesSyncBlocked: RELAY_UPGRADE_MESSAGE, InvitationExpired: "邀请已过期，请生成新邀请。",
    ApprovalConflict: "设备组已变化，此次审批未完成；请刷新后重新核对。",
    ManagerRequired: "此操作需要设备组管理员。", VerificationCodeMismatch: "配对码不一致，请重新核对。",
    AnotherJoinPending: "已有待处理的入组申请，请先完成当前申请。", LegacyRelayResetRequired: "旧手动接入需要重新建组：请清除本机接入后重新创建或加入设备组。",
    GroupAccessRevoked: "本机设备组权限已被撤销。",
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
export function relayOnLock() { if (!isMac) void Relay.disconnect(vaultInstance).catch(() => {}); connection.set({ transport: "disconnected", online: [] }); ++generation; summary.set({}); roster.set({}); failure.set(""); closeSheet(); }
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
      bumpNoteAssets();
      void refreshItems().then(refreshRelay).catch(() => {});
    }
  });
  return () => { stop(); if (!isMac) void Relay.disconnect(vaultInstance).catch(() => {}); };
});
/** Safe sidebar accessor: membership never implies a live connection. */
export function syncStatus(): string {
  if (phase() !== "unlocked") return "已锁定 · 同步已断开";
  const noteConflictCount = Object.keys(meshConflicts()).length || Number(summary().conflictCount ?? 0);
  if (noteConflictCount > 0) return `${noteConflictCount} 篇笔记有并行分支待处理`;
  if (roster().state && connection().transport !== "connected") return ({ connecting: "正在连接中继…", reconnecting: "离线可用 · 正在重连中继…" } as Record<string,string>)[connection().transport] ?? "离线可用 · 本地完整读写";
  if (meshSync()) {
    const remoteCount = Number(summary().remoteAssetCount ?? 0);
    return connection().transport === "connected"
      ? (remoteCount > 0 ? `已同步 · L1 优先（${remoteCount} 附件按需）` : "已同步 · L1 元数据优先双向同步")
      : "离线可用 · 本地完整读写";
  }
  return ({ connected: "设备组已连接", connecting: "正在连接设备组…", reconnecting: "等待重新连接…" } as Record<string,string>)[connection().transport] ?? "中继未连接";
}
/** Tone for the sidebar status dot, derived from the same state as `syncStatus`. */
export function syncTone(): "ok" | "busy" | "warn" | "off" {
  if (phase() !== "unlocked") return "off";
  const noteConflictCount = Object.keys(meshConflicts()).length || Number(summary().conflictCount ?? 0);
  if (noteConflictCount > 0) return "warn";
  const transport = connection().transport;
  if (transport === "connected") return "ok";
  if (transport === "connecting" || transport === "reconnecting") return "busy";
  return roster().state || meshSync() ? "warn" : "off";
}
export async function refreshRelay() {
  const epoch = ++generation;
  if (phase() !== "unlocked") { summary.set({}); roster.set({}); return; }
  refreshing.set(true);
  try {
    const [state, group] = await Promise.all([coreApi.relayStatus(), Relay.summary(vaultInstance)]);
    const parsed = JSON.parse(group);
    await refreshMeshConflicts();
    if (epoch !== generation || phase() !== "unlocked") return;
    summary.set(state); roster.set(parsed);
    failure.set("");
  } catch (e) { if (epoch === generation && phase() === "unlocked") failure.set(relayErrorText(e)); }
  finally { if (epoch === generation) refreshing.set(false); }
}
/** Only pass an already-created invitation link. Never logs the fragment key. */
export function InvitationQR(props: { link: string; size?: number }) {
  const matrix = signal<boolean[][]>([]);
  const px = () => props.size ?? 232;
  effect(() => { try { matrix.set(JSON.parse(Relay.qr(props.link))); } catch { matrix.set([]); } });
  return <Canvas accessibilityLabel="设备组邀请二维码" style={{ width: px(), height: px() }} draw={(cx, size) => {
    cx.fillStyle = "#ffffff"; cx.fillRect(0, 0, size.width, size.height);
    const rows = matrix(); if (!rows.length) return;
    const unit = Math.floor(Math.min(size.width, size.height) / rows.length);
    const ox = Math.floor((size.width - rows.length * unit) / 2), oy = Math.floor((size.height - rows.length * unit) / 2);
    cx.fillStyle = "#000000";
    rows.forEach((row, y) => row.forEach((dark, x) => { if (dark) cx.fillRect(ox + x * unit, oy + y * unit, unit, unit); }));
  }} />;
}
async function groupAction(request: Record<string, unknown>) {
  if (acting() || phase() !== "unlocked") throw new Error("Locked");
  acting.set(true); failure.set("");
  try { await Relay.action(vaultInstance, JSON.stringify(request)); if (phase() === "unlocked") { const status = JSON.parse(await Relay.connectionStatus(vaultInstance)); if (phase() === "unlocked") { connection.set(status); await refreshRelay(); } } }
  catch (e) { failure.set(relayErrorText(e)); await refreshRelay().catch(() => {}); failure.set(relayErrorText(e)); throw e; }
  finally { acting.set(false); }
}
export function RelayPage() {
  effect(() => { if (phase() === "unlocked") void refreshRelay(); else { ++generation; summary.set({}); roster.set({}); failure.set(""); closeSheet(); } });
  const conflictList = () => Object.values(meshConflicts());
  return <View style={{ gap: 14 }}>
    <T size={19} weight="600">同步与设备</T>
    <If when={roster().state && meshSync()}>
      <Group style={{ gap: 6, paddingVertical: 10 }}>
        <Row gap={8} wrap>
          <T weight="600">{roster().state?.name || "我的密码库"}</T>
          <Pill tone="blue">L1 元数据优先</Pill>
          <If when={Number(summary().remoteAssetCount ?? 0) > 0}>
            <Pill tone="gray">{summary().remoteAssetCount} 个大附件按需下载</Pill>
          </If>
        </Row>
        <T size={12} color={c().muted}>密码、笔记正文与 512 KB 以上附件元数据优先毫秒级同步，大附件不阻塞队列、点击时端到端按需拉取。非重叠章节与标签自动合并，重叠编辑保留并行分支供本机解决。</T>
      </Group>
    </If>
    <If when={conflictList().length > 0}>
      <Banner tone="warn" title={`${conflictList().length} 篇笔记存在并发编辑并行分支`}>
        两端附件已自动取并集保护（0 项丢失），点击下方进入本机分屏解决。
      </Banner>
      <Group>
        {conflictList().map((cf) => (
          <Row style={{ paddingVertical: 10 }} gap={8}>
            <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
              <T weight="600" lines={1}>{cf.title || "未命名笔记"}</T>
              <T size={11.5} color={c().muted} lines={1}>冲突位置：{cf.section} · {cf.localDevice} ↔ {cf.remoteDevice}</T>
            </View>
            <Btn label="分屏解决" kind="primary" onPress={() => openConflictResolver(cf.noteId)} />
          </Row>
        ))}
      </Group>
    </If>
    <If when={meshSync() && Number(summary().archivedConflicts ?? 0) > 0}><Banner tone="info" title={`升级时 ${summary().archivedConflicts} 个旧冲突版本已存入条目历史`}>无需再手动处理冲突；需要时可在对应条目的历史中恢复。</Banner></If>
    <If when={meshSync() && summary().skew === true}><Banner tone="warn" title="有设备的系统时间明显不准">同时修改时以时间较新的修改为准，请校准该设备时间。</Banner></If>
    <If when={!roster().state}><Banner tone="info" title="扫码加入，L1 元数据优先自动同步">创建设备组，或在其他设备上扫描邀请二维码加入。优先同步密码与笔记索引，大附件按需拉取，离线时本机仍完整读写。</Banner></If>
    <Group>
      <View style={{ gap: 6, paddingVertical: 8 }}>
        <Row gap={8} wrap>
          <View style={{ flex: 1, minWidth: 160 }}><T weight="600">{syncStatus()}</T></View>
          <Btn label={refreshing() ? "刷新中…" : "刷新记录"} disabled={refreshing()} onPress={() => void refreshRelay()} />
          <Btn
            label={syncing() ? "同步中…" : "立即同步"}
            disabled={syncing() || !roster().state}
            onPress={async () => {
              syncing.set(true);
              try { await Relay.syncNow(vaultInstance); } catch(e) { failure.set(relayErrorText(e)); }
              finally { syncing.set(false); }
            }}
          />
        </Row>
        <If when={!roster().state}>
          <T size={11} color={c().muted}>门控原因：尚未加入设备组，创建或加入后启用「立即同步」。</T>
        </If>
      </View>
    </Group>
    <If when={failure()}><Banner tone="err" title={failure()} /></If>
    <If when={connection().error}><Banner tone="warn" title={relayErrorText(connection().error)} /></If>
    <If when={connection().exit}><Banner tone={connection().exit?.remote === "failed" ? "warn" : "info"} title={exitNotice(connection().exit ?? {})}>本地资料已保留；退出后不会自动恢复旧组连接。</Banner></If>
    <T weight="600">设备组</T>
    <GroupPanel group={roster()} busy={acting()} act={groupAction} online={connection().online ?? []} />
    <If when={!roster().state?.members?.length}><T color={c().muted}>本地没有设备组记录</T></If>
  </View>;
}
