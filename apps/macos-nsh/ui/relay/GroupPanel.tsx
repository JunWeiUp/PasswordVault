import { View, signal, Picker, cleanup } from "nsh";
import { Relay } from "passwordvault/native";
import { Banner, Btn, Group, Row, T, TextBox, Toggle, confirm, copySecret, openSheet, SheetTitle, SheetFooter } from "../kit";
import { onLock } from "../store";
import { c } from "../theme";
import { InvitationQR, relayErrorText } from "./index";
function ExitConfirmation(props: { op: "leave" | "disband"; close: () => void; act: (v: Record<string, unknown>) => Promise<void> }) {
  const busy = signal(false), error = signal("");
  let alive = true;
  cleanup(() => { alive = false; });
  cleanup(onLock(props.close));
  const submit = async () => {
    if (busy()) return;
    busy.set(true); error.set("");
    try { await props.act({ op: props.op }); if (alive) props.close(); }
    catch (e) { if (alive) error.set(relayErrorText(e)); }
    finally { if (alive) busy.set(false); }
  };
  return <View style={{ gap: 12 }}>
    <SheetTitle title={props.op === "leave" ? "退出设备组" : "解散设备组"} text={props.op === "leave" ? "同步日志将加密归档，本地资料保留，本机设备标识会更新。服务器退出结果会另行显示。" : "本机先退出，再尝试通知服务器解散设备组；各设备已经保存的资料不会被远程删除。"} />
    <T size={12}>确认后立即退出本机接入并保留本地资料，不再同步。将另行通知服务器；即使通知失败，本机也保持退出。服务器未确认时，其他设备的组状态可能不变。</T>
    <If when={error()}><Banner tone="err" title="操作未完成">{error()}</Banner></If>
    <SheetFooter><Btn label="取消" disabled={busy()} onPress={props.close} /><Btn label={busy() ? "正在处理…" : props.op === "leave" ? "退出" : "解散"} kind="dangerSolid" disabled={busy()} onPress={() => void submit()} /></SheetFooter>
  </View>;
}
export function GroupPanel(props: { group: any; busy: boolean; act: (v: Record<string, unknown>) => Promise<void> }) {
  const endpoint = signal(""), relayPassword = signal(""), joinPassword = signal(""), groupName = signal("我的设备"), deviceName = signal("这台 Mac"), link = signal("");
  const scanning = signal(false), scanError = signal(""), scanned = signal(false);
  const scanImage = async () => {
    if (scanning() || props.busy) return;
    scanning.set(true); scanError.set("");
    try {
      const picked = await Picker.pickImages({ multiple: false, format: "compatible" });
      if (!picked.length) return;
      if (picked[0].file.size > 20 * 1024 * 1024) throw new Error("RelayQrTooLarge");
      const value = await Relay.invitationImage(new Uint8Array(await picked[0].file.arrayBuffer()));
      link.set(value); joinPassword.set(""); scanned.set(true);
    } catch (error) { scanError.set(relayErrorText(error)); }
    finally { scanning.set(false); }
  };
  const promote = signal(false);
  const automatic = signal(true), code = signal(""), renamed = signal("");
  const manager = () => (props.group.state?.members ?? []).some((m: any) => m.device === props.group.device && m.manager);
  const act = (v: Record<string, unknown>) => void props.act(v).catch(() => {});
  const exit = (op: "leave" | "disband") => openSheet({ render: close => <ExitConfirmation op={op} close={close} act={props.act} /> });
  cleanup(onLock(() => { relayPassword.set(""); joinPassword.set(""); }));
  return <View style={{ gap: 12 }}>
    <If when={props.group.legacy}><Banner tone="warn" title="旧手动接入需要显式迁移">请先在现有 SwiftUI 版迁移，或清除本机接入后重新建组。</Banner></If>
    <If when={props.group.legacy || (props.group.state && !(props.group.state.members ?? []).some((m: any) => m.device === props.group.device))}>
      <Btn label="清除本机接入" disabled={props.busy} onPress={() => confirm({ title: "清除本机接入", text: "归档本机同步日志、保留资料并更新设备标识。此操作不会撤销服务器上的旧凭据。", ok: "清除接入", danger: true, onConfirm: () => act({ op: "clear-local" }) })} />
    </If>
    <If when={!props.group.legacy && !props.group.state && !props.group.joining}>
      <Group style={{ gap: 8, paddingVertical: 12 }}>
        <T weight="600">创建自己的设备组</T>
        <T size={12} color={c().muted}>填写中继地址和密码，创建用于连接你的设备的设备组。</T>
        <TextBox value={endpoint()} onChange={(v) => endpoint.set(v)} label="中继地址" placeholder="wss://…/relay/v1/ws" testID="relay-endpoint" />
        <TextBox value={relayPassword()} onChange={(v) => relayPassword.set(v)} label="中继密码" placeholder="输入中继密码" masked testID="relay-password" />
        <T size={11} color={c().muted}>请输入中继服务的访问密码。</T>
        <TextBox value={groupName()} onChange={(v) => groupName.set(v)} label="设备组名称" placeholder="例如：我的设备" />
        <TextBox value={deviceName()} onChange={(v) => deviceName.set(v)} placeholder="本机名称" />
        <Btn label={props.group.creating ? "重试创建设备组" : "创建设备组"} kind="primary" disabled={props.busy || (!props.group.creating && (!endpoint() || !relayPassword() || !groupName().trim()))} onPress={() => { act({ op: "create", endpoint: endpoint(), relayPassword: relayPassword(), name: groupName(), deviceName: deviceName() }); relayPassword.set(""); }} />
      </Group>
      <If when={!props.group.creating}><Group style={{ gap: 8, paddingVertical: 12 }}>
        <T weight="600">加入现有设备组</T>
        <Btn label={scanning() ? "正在识别二维码…" : "识别邀请二维码图片"} icon="qr" disabled={props.busy || scanning()} onPress={() => void scanImage()} />
        <TextBox value={link()} onChange={(v) => { link.set(v); scanned.set(false); }} masked placeholder="粘贴 common-relay:// 邀请链接" />
        <If when={scanned()}><T size={12}>已识别邀请二维码，点击加入设备组继续。</T></If>
        <If when={scanError()}><Banner tone="err" title="无法识别邀请">{scanError()}</Banner></If>
        <TextBox value={joinPassword()} onChange={(v) => joinPassword.set(v)} label="中继密码" placeholder="邀请已包含密码时可留空" masked testID="join-relay-password" />
        <T size={11} color={c().muted}>二维码图片或新版邀请链接会自动带上中继密码；旧链接请手动输入。图片仅在本机识别。</T>
        <TextBox value={deviceName()} onChange={(v) => deviceName.set(v)} placeholder="本机名称" />
        <Btn label="加入设备组" disabled={props.busy || scanning() || !link()} onPress={() => { act({ op: "join", link: link(), relayPassword: joinPassword(), deviceName: deviceName() }); joinPassword.set(""); }} />
      </Group></If>
    </If>
    <If when={props.group.state || props.group.joining}>
      <Group style={{ gap: 8, paddingVertical: 12 }}>
        <T weight="600">更新中继密码</T>
        <T size={12} color={c().muted}>保存本机使用的服务器访问密码，保留设备组身份。连接验证失败时请修正后重试；这不会修改服务器本身的密码。</T>
        <TextBox masked value={relayPassword()} onChange={v => relayPassword.set(v)} label="新的中继密码" testID="update-relay-password" />
        <Btn label="保存中继密码并重连" disabled={props.busy || !relayPassword()} onPress={() => { act({ op: "update-password", relayPassword: relayPassword() }); relayPassword.set(""); }} />
      </Group>
    </If>
    <If when={props.group.joining}>
      <Banner tone="info" title="等待入组确认">请与邀请方核对配对码：{props.group.code}</Banner>
      <Row><Btn label="检查审批结果" disabled={props.busy} onPress={() => act({ op: "finish-join" })} /><Btn label="重试加入" disabled={props.busy} onPress={() => act({ op: "retry-join" })} /></Row>
    </If>
    <If when={props.group.state}>
      <Row><T weight="600" style={{ flex: 1 }}>{props.group.state?.name || "设备组"}</T><Btn label="刷新设备组" disabled={props.busy} onPress={() => act({ op: "refresh" })} /></Row>
      <If when={manager()}>
        <Toggle title="自动加入普通成员" note="关闭后须核对配对码并手动批准；两种模式均不自动授权密码库" checked={automatic()} onChange={(v) => automatic.set(v)} disabled={props.busy || !!props.group.invitationLink} />
        <Btn label="生成邀请二维码" disabled={props.busy || !!props.group.invitationLink} onPress={() => act({ op: "invite", mode: automatic() ? "auto" : "manual" })} />
        <If when={props.group.invitationLink}>
          <InvitationQR link={props.group.invitationLink} />
          <T size={11} color={c().muted}>邀请链接含入组密钥和中继访问密码，请只交给你信任的设备。</T>
          <TextBox value={props.group.invitationLink || ""} onChange={() => {}} masked label="邀请链接" />
          <Row><Btn label="复制邀请链接" onPress={() => void copySecret(props.group.invitationLink, "邀请链接")} /><Btn label="取消邀请" disabled={props.busy} onPress={() => act({ op: "cancel-invitation" })} /><If when={props.group.invitationMode === "manual"}><Btn label="检查加入申请" disabled={props.busy} onPress={() => act({ op: "check-request" })} /></If></Row>
        </If>
        <If when={props.group.applicant}>
          <Banner tone="info" title={`${props.group.applicant} 申请加入`}>双方配对码应一致：{props.group.code}</Banner>
          <TextBox value={code()} onChange={(v) => code.set(v.toUpperCase())} placeholder="输入对方显示的配对码" />
          <Toggle title="同时授予设备组管理权限" note="管理设备组不等于授权密码库" checked={promote()} onChange={(v) => promote.set(v)} disabled={props.busy} />
          <Btn label={promote() ? "批准为管理员" : "批准为普通成员"} disabled={props.busy || code() !== props.group.code} onPress={() => act({ op: "approve", code: code(), manager: promote() })} />
        </If>
      </If>
      <Group style={{ gap: 8, paddingVertical: 12 }}>
        <TextBox value={renamed()} onChange={(v) => renamed.set(v)} placeholder="新的设备名称" />
        {(props.group.state?.members ?? []).map((m: any) => <Row><T style={{ flex: 1 }}>{m.name}{m.device === props.group.device ? " · 本机" : ""}{m.manager ? " · 管理员" : ""}</T>
          <If when={manager() || m.device === props.group.device}><Btn label="重命名" disabled={props.busy || !renamed().trim()} onPress={() => act({ op: "rename", device: m.device, name: renamed() })} /></If>
          <If when={manager() && m.device !== props.group.device}><Btn label="移除" kind="danger" disabled={props.busy} onPress={() => confirm({ title: `移除 ${m.name}`, text: "将撤销其设备组成员资格。本机密码库资料会保留。", ok: "移除设备", danger: true, onConfirm: () => act({ op: "remove", device: m.device }) })} /></If>
        </Row>)}
      </Group>
      <Row><Btn label="退出设备组" disabled={props.busy} onPress={() => exit("leave")} />
      <If when={manager()}><Btn label="解散设备组" kind="danger" disabled={props.busy} onPress={() => exit("disband")} /></If></Row>
    </If>
  </View>;
}
