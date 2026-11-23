import { View, signal, effect, Picker, cleanup } from "nsh";
import { Relay } from "passwordvault/native";
import { Banner, Btn, Group, OptionRow, Pill, Row, T, TextBox, confirm, copySecret, openSheet, SheetTitle, SheetFooter } from "../kit";
import { onLock } from "../store";
import { c } from "../theme";
import { InvitationQR, relayErrorText } from "./index";
import { keyFingerprint } from "./fingerprint";

function formatRemaining(expiresSec?: number, nowMs = Date.now()): string {
  const exp = Number(expiresSec ?? 0);
  if (!Number.isFinite(exp) || exp <= 0) return "";
  const left = Math.max(0, Math.floor(exp - nowMs / 1000));
  if (left <= 0) return "邀请已过期，请取消后重新生成";
  const m = String(Math.floor(left / 60)).padStart(2, "0");
  const s = String(left % 60).padStart(2, "0");
  return `剩余 ${m}:${s}`;
}

function InviteDeviceSheet(props: {
  group: () => any;
  busy: () => boolean;
  close: () => void;
  act: (v: Record<string, unknown>) => Promise<void>;
}) {
  const now = signal(Date.now());
  const code = signal("");
  const canceling = signal(false);
  const error = signal("");
  let alive = true;
  const timer = setInterval(() => { if (alive) now.set(Date.now()); }, 1000);
  cleanup(() => { alive = false; clearInterval(timer); });
  cleanup(onLock(props.close));

  const link = () => String(props.group()?.invitationLink || "");
  const mode = () => String(props.group()?.invitationMode || "auto");
  const manual = () => mode() === "manual";
  const remaining = () => formatRemaining(props.group()?.invitationExpires, now());

  effect(() => {
    if (!link() && alive) props.close();
  });

  const cancelInvite = async () => {
    if (canceling() || props.busy()) return;
    canceling.set(true); error.set("");
    try {
      await props.act({ op: "cancel-invitation" });
      if (alive) props.close();
    } catch (e) {
      if (alive) error.set(relayErrorText(e));
    } finally {
      if (alive) canceling.set(false);
    }
  };

  const runAct = async (req: Record<string, unknown>) => {
    error.set("");
    try { await props.act(req); }
    catch (e) { if (alive) error.set(relayErrorText(e)); }
  };

  const subtitle = () => manual()
      ? "新设备扫描后提交申请，核对双方配对码一致后再批准加入。请只交给你自己的设备。"
      : "在新设备上扫描即可加入并立即双向同步全部密码库内容，无需再确认。请只交给你自己的设备。";

  return <View style={{ gap: 14 }}>
    <SheetTitle title="邀请设备" text={subtitle()} />
    <Row gap={20} style={{ alignItems: "center" }}>
      <View style={{ padding: 10, backgroundColor: "#ffffff", borderWidth: 1, borderColor: c().line, borderRadius: 10, flexShrink: 0 }}>
        <InvitationQR link={link()} size={168} />
      </View>
      <View style={{ flex: 1, minWidth: 0, gap: 8 }}>
        <T size={12} weight="600" color={c().ink2}>邀请链接</T>
        <TextBox value={link()} onChange={() => {}} masked label="邀请链接" />
        <T size={11.5} color={c().muted}>{"邀请链接包含中继地址与中继访问密码，加入方无需另行填写。\n邀请 10 分钟内有效，只能使用一次。"}</T>
        <If when={remaining()}><T size={11.5} color={c().muted} mono>{remaining()}</T></If>
      </View>
    </Row>
    <If when={manual()}>
      <View style={{ gap: 8 }}>
        <Row gap={8}>
          <Btn label="检查加入申请" disabled={props.busy() || canceling()} onPress={() => void runAct({ op: "check-request" })} />
        </Row>
        <If when={props.group()?.applicant}>
          <Banner tone="info" title={`${props.group()?.applicant} 申请加入`} style={{ marginBottom: 0 }}>双方配对码应一致：{props.group()?.code}</Banner>
          <TextBox value={code()} onChange={(v) => code.set(v.toUpperCase())} placeholder="输入对方显示的配对码" />
          <Row><Btn label="批准加入设备组" kind="primary" disabled={props.busy() || code() !== props.group()?.code} onPress={() => void runAct({ op: "approve", code: code(), manager: false })} /></Row>
        </If>
      </View>
    </If>
    <If when={error()}><Banner tone="err" title="操作未完成" style={{ marginBottom: 0 }}>{error()}</Banner></If>
    <SheetFooter left={<Btn label={canceling() ? "正在取消…" : "取消邀请"} kind="danger" disabled={props.busy() || canceling()} onPress={() => void cancelInvite()} />}>
      <Btn label="复制邀请链接" icon="link" onPress={() => void copySecret(link(), "邀请链接")} />
      <Btn label="完成" kind="primary" onPress={props.close} />
    </SheetFooter>
  </View>;
}

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

function RenameDeviceSheet(props: { device: string; currentName: string; close: () => void; act: (v: Record<string, unknown>) => Promise<void> }) {
  const draft = signal(props.currentName || "");
  const busy = signal(false), error = signal("");
  let alive = true;
  cleanup(() => { alive = false; });
  cleanup(onLock(props.close));
  const canSubmit = () => !busy() && !!draft().trim() && draft().trim() !== (props.currentName || "").trim();
  const submit = async () => {
    const clean = draft().trim();
    if (!canSubmit()) return;
    busy.set(true); error.set("");
    try { await props.act({ op: "rename", device: props.device, name: clean }); if (alive) props.close(); }
    catch (e) { if (alive) error.set(relayErrorText(e)); }
    finally { if (alive) busy.set(false); }
  };
  return <View style={{ gap: 12 }}>
    <SheetTitle title="重命名设备" text={`为「${props.currentName || "未命名设备"}」设置更易辨识的名称，会同步给设备组内其他成员。`} />
    <TextBox value={draft()} onChange={(v) => draft.set(v)} label="设备名称" placeholder="例如：办公室 MacBook Pro" autoFocus onSubmit={() => void submit()} testID="rename-device-input" />
    <If when={error()}><Banner tone="err" title="重命名未完成">{error()}</Banner></If>
    <SheetFooter>
      <Btn label="取消" disabled={busy()} onPress={props.close} />
      <Btn testID="rename-device-submit" label={busy() ? "正在保存…" : "保存名称"} kind="primary" disabled={!canSubmit()} onPress={() => void submit()} />
    </SheetFooter>
  </View>;
}

export function GroupPanel(props: { group: any; busy: boolean; online?: string[]; act: (v: Record<string, unknown>) => Promise<void> }) {
  const endpoint = signal(""), relayPassword = signal(""), joinPassword = signal(""), groupName = signal("我的设备"), deviceName = signal("这台电脑"), link = signal("");
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
  const code = signal(""), connectionSettings = signal(false);
  const members = (): any[] => props.group.state?.members ?? [];
  const manager = () => members().some((m: any) => m.device === props.group.device && m.manager);
  const act = (v: Record<string, unknown>) => void props.act(v).catch(() => {});
  const joinMode = signal<"auto" | "manual">("auto");

  const approval = (note: string) => <If when={props.group.applicant}>
    <View style={{ gap: 8, paddingTop: 4 }}>
      <Banner tone="info" title={`${props.group.applicant} 申请加入`} style={{ marginBottom: 0 }}>双方配对码应一致：{props.group.code}</Banner>
      <TextBox value={code()} onChange={(v) => code.set(v.toUpperCase())} placeholder="输入对方显示的配对码" />
      <T size={12} color={c().muted}>{note}</T>
      <Row><Btn label="批准加入设备组" kind="primary" disabled={props.busy || code() !== props.group.code} onPress={() => act({ op: "approve", code: code(), manager: false })} /></Row>
    </View>
  </If>;

  const showKey = (m: any) => openSheet({ render: close => <View style={{ gap: 10 }}>
    <SheetTitle title={`${m.name} 的公钥指纹`} text="设备组记录中固定的签名公钥。可与该设备“设置 › 同步”中显示的指纹逐组核对。" />
    <View style={{ backgroundColor: c().soft2, borderWidth: 1, borderColor: c().line, borderRadius: 8, padding: 12 }}>
      <T mono size={13} selectable>{keyFingerprint(m.signing_key)}</T>
    </View>
    <SheetFooter><Btn label="完成" kind="primary" onPress={close} /></SheetFooter>
  </View> });

  const renameDevice = (m: any) => openSheet({
    width: 440,
    render: (close) => <RenameDeviceSheet device={m.device} currentName={m.name} close={close} act={props.act} />,
  });

  const openInviteSheet = () => openSheet({
    width: 540,
    render: (close) => <InviteDeviceSheet group={() => props.group} busy={() => props.busy} close={close} act={props.act} />,
  });

  const startInvite = async (mode: "auto" | "manual") => {
    try {
      await props.act({ op: "invite", mode });
      if (props.group.invitationLink) openInviteSheet();
    } catch {}
  };

  const exit = (op: "leave" | "disband") => openSheet({ render: close => <ExitConfirmation op={op} close={close} act={props.act} /> });
  cleanup(onLock(() => { relayPassword.set(""); joinPassword.set(""); }));

  return <View style={{ gap: 14 }}>
    <If when={props.group.legacy}><Banner tone="warn" title="旧手动接入需要重新建组" style={{ marginBottom: 0 }}>请清除本机接入后重新创建或加入设备组。</Banner></If>
    <If when={props.group.legacy || (props.group.state && !members().some((m: any) => m.device === props.group.device))}>
      <Row><Btn label="清除本机接入" kind="danger" disabled={props.busy} onPress={() => confirm({ title: "清除本机接入", text: "归档本机同步日志、保留资料并更新设备标识。此操作不会撤销服务器上的旧凭据。", ok: "清除接入", danger: true, onConfirm: () => act({ op: "clear-local" }) })} /></Row>
    </If>

    {/* Onboarding: Create or Join */}
    <If when={!props.group.legacy && !props.group.state && !props.group.joining}>
      <Group style={{ gap: 8, paddingVertical: 12 }}>
        <T weight="600">创建自己的设备组</T>
        <T size={12} color={c().muted}>创建后，用其他设备扫描邀请二维码即可加入，组内所有设备自动双向同步。</T>
        <TextBox value={endpoint()} onChange={(v) => endpoint.set(v)} label="中继地址" placeholder="wss://…/v2/ws" testID="relay-endpoint" />
        <TextBox value={relayPassword()} onChange={(v) => relayPassword.set(v)} label="中继密码" placeholder="输入中继密码" masked testID="relay-password" />
        <T size={11} color={c().muted}>请输入中继服务的访问密码。</T>
        <TextBox value={groupName()} onChange={(v) => groupName.set(v)} label="设备组名称" placeholder="例如：我的设备" />
        <TextBox value={deviceName()} onChange={(v) => deviceName.set(v)} placeholder="本机名称" />
        <Row gap={8} wrap>
          <Btn label={props.group.creating ? "重试创建设备组" : "创建设备组"} kind="primary" disabled={props.busy || (!props.group.creating && (!endpoint() || !relayPassword() || !groupName().trim()))} onPress={() => { act({ op: "create", endpoint: endpoint(), relayPassword: relayPassword(), name: groupName(), deviceName: deviceName() }); relayPassword.set(""); }} />
          <If when={!props.group.creating && (!endpoint() || !relayPassword() || !groupName().trim())}>
            <T size={11} color={c().muted}>需填写中继地址、中继密码和设备组名称后启用</T>
          </If>
        </Row>
      </Group>
      <If when={!props.group.creating}><Group style={{ gap: 8, paddingVertical: 12 }}>
        <T weight="600">加入现有设备组</T>
        <Row><Btn label={scanning() ? "正在识别二维码…" : "识别邀请二维码图片"} icon="qr" disabled={props.busy || scanning()} onPress={() => void scanImage()} /></Row>
        <TextBox value={link()} onChange={(v) => { link.set(v); scanned.set(false); }} masked placeholder="粘贴 common-relay:// 邀请链接" />
        <If when={scanned()}><T size={12}>已识别邀请二维码，点击加入设备组继续。</T></If>
        <If when={scanError()}><Banner tone="err" title="无法识别邀请" style={{ marginBottom: 0 }}>{scanError()}</Banner></If>
        <TextBox value={joinPassword()} onChange={(v) => joinPassword.set(v)} label="中继密码" placeholder="邀请已包含密码时可留空" masked testID="join-relay-password" />
        <T size={11} color={c().muted}>二维码图片或新版邀请链接会自动带上中继密码；旧链接请手动输入。图片仅在本机识别。</T>
        <TextBox value={deviceName()} onChange={(v) => deviceName.set(v)} placeholder="本机名称" />
        <Row gap={8} wrap>
          <Btn label="加入设备组" disabled={props.busy || scanning() || !link()} onPress={() => { act({ op: "join", link: link(), relayPassword: joinPassword(), deviceName: deviceName() }); joinPassword.set(""); }} />
          <If when={!link()}>
            <T size={11} color={c().muted}>请先识别二维码或粘贴邀请链接</T>
          </If>
        </Row>
      </Group></If>
    </If>

    {/* Pending Join */}
    <If when={props.group.joining}>
      <Banner tone="info" title="等待入组确认" style={{ marginBottom: 0 }}>请与邀请方核对配对码：{props.group.code}</Banner>
      <Row><Btn label="检查审批结果" kind="primary" disabled={props.busy} onPress={() => act({ op: "finish-join" })} /><Btn label="重试加入" disabled={props.busy} onPress={() => act({ op: "retry-join" })} /></Row>
    </If>

    {/* Active Group: Header, Invite & Connection Settings */}
    <If when={props.group.state}>
      <Group style={{ gap: 10, paddingVertical: 12 }}>
        <Row gap={8} wrap>
          <View style={{ flex: 1, minWidth: 160, gap: 2 }}>
            <Row gap={6} wrap>
              <T size={14} weight="600">{props.group.state?.name || "设备组"}</T>
              <Pill tone="info">{members().length} 台设备</Pill>
            </Row>
            <T size={11.5} color={c().muted}>
              个人对称双向同步 · 端到端加密
            </T>
          </View>
          <Btn label={connectionSettings() ? "收起连接设置" : "连接设置"} onPress={() => connectionSettings.set(!connectionSettings())} />
          <Btn label="刷新设备组" disabled={props.busy} onPress={() => act({ op: "refresh" })} />
        </Row>

        <If when={connectionSettings()}>
          <View style={{ borderTopWidth: 1, borderTopColor: c().line2, paddingTop: 10, gap: 8 }}>
            <T size={12.5} weight="600">中继地址</T>
            <T size={11.5} color={c().muted}>支持切换到 wss://…/v2/ws 或保留 wss://…/relay/v1/ws，修改后保留原有设备组与访问密码。</T>
            <TextBox value={endpoint() || props.group.endpoint || ""} onChange={v => endpoint.set(v)} label="中继地址" placeholder="wss://…/v2/ws" testID="update-relay-endpoint" />
            <Row><Btn label="保存中继地址并重连" disabled={props.busy || !(endpoint() || props.group.endpoint || "").trim()} onPress={() => { const next = (endpoint() || props.group.endpoint || "").trim(); act({ op: "update-endpoint", endpoint: next }); }} /></Row>
            <T size={12.5} weight="600" style={{ marginTop: 6 }}>更新中继密码</T>
            <T size={11.5} color={c().muted}>保存本机使用的服务器访问密码，保留设备组身份。连接验证失败时请修正后重试；这不会修改服务器本身的密码。</T>
            <TextBox masked value={relayPassword()} onChange={v => relayPassword.set(v)} label="新的中继密码" testID="update-relay-password" />
            <Row><Btn label="保存中继密码并重连" kind="primary" disabled={props.busy || !relayPassword()} onPress={() => { act({ op: "update-password", relayPassword: relayPassword() }); relayPassword.set(""); }} /></Row>
          </View>
        </If>

        <If when={manager()}>
          <View style={{ borderTopWidth: 1, borderTopColor: c().line2, paddingTop: 10, gap: 8 }}>
            <If when={!props.group.invitationLink}>
              <Row gap={8} wrap>
                <T size={12} weight="600" color={c().ink2}>加入方式</T>
                <Btn testID="join-mode-auto" label="扫码后自动加入" kind={joinMode() === "auto" ? "primary" : undefined} onPress={() => joinMode.set("auto")} />
                <Btn testID="join-mode-manual" label="核对配对码后批准" kind={joinMode() === "manual" ? "primary" : undefined} onPress={() => joinMode.set("manual")} />
                <View style={{ flex: 1 }} />
                <Btn label="邀请设备" icon="qr" kind="primary" disabled={props.busy || !!props.group.invitationLink} onPress={() => void startInvite(joinMode())} />
              </Row>
            </If>
            <T size={11.5} color={c().muted}>{(props.group.invitationLink ? props.group.invitationMode : joinMode()) === "manual"
              ? "新设备扫描后提交申请，你在这里核对双方配对码一致后再批准加入。邀请 10 分钟内有效，只能使用一次。"
              : "在新设备上扫描二维码即可加入并开始双向同步，无需再确认。邀请 10 分钟内有效，只能使用一次。"}</T>
            <If when={props.group.invitationLink}>
              <Row gap={8} wrap>
                <Btn label="查看邀请二维码" icon="qr" kind="primary" onPress={openInviteSheet} />
                <Btn label="复制邀请链接" icon="link" onPress={() => void copySecret(props.group.invitationLink, "邀请链接")} />
                <If when={props.group.invitationMode === "manual"}><Btn label="检查加入申请" disabled={props.busy} onPress={() => act({ op: "check-request" })} /></If>
                <Btn label="取消邀请" kind="danger" disabled={props.busy} onPress={() => act({ op: "cancel-invitation" })} />
              </Row>
            </If>
            {approval("批准后该设备加入设备组，并与组内设备双向同步全部密码库内容。")}
          </View>
        </If>

        <If when={!manager()}>
          <View style={{ borderTopWidth: 1, borderTopColor: c().line2, paddingTop: 10 }}>
            <T size={12} color={c().muted}>{`请在管理设备“${members().find((m: any) => m.manager)?.name ?? "创建者"}”上邀请新设备。`}</T>
          </View>
        </If>

      </Group>

      {/* Members List */}
      <View style={{ gap: 7 }}>
        <T size={12} weight="600" color={c().muted}>设备组成员（{members().length}）</T>
        <Group>
          {members().map((m: any, idx: number) => {
            const isSelf = m.device === props.group.device;
            const isOnline = !!props.online?.includes(m.device);
            const hasKey = !!keyFingerprint(m.signing_key);
            const isLast = idx === members().length - 1;
            return (
              <Row
                gap={10}
                style={{
                  paddingVertical: 11,
                  borderBottomWidth: isLast ? 0 : 1,
                  borderBottomColor: c().line2,
                }}
              >
                <View style={{ flex: 1, minWidth: 0, gap: 3 }}>
                  <Row gap={6} wrap>
                    <T size={13} weight="600" lines={1}>{m.name}</T>
                    <If when={isSelf}><Pill tone="info">本机</Pill></If>
                    <If when={m.manager}><Pill tone="neutral">管理</Pill></If>
                  </Row>
                  <Row gap={6}>
                    <View
                      style={{
                        width: 6,
                        height: 6,
                        borderRadius: 3,
                        backgroundColor: isSelf || isOnline ? c().green : c().faint,
                      }}
                    />
                    <T size={11.5} color={isSelf || isOnline ? c().ink2 : c().muted}>
                      {isSelf ? "当前设备" : isOnline ? "在线" : "离线"}
                    </T>
                  </Row>
                </View>
                <Row gap={6}>
                  <If when={hasKey}>
                    <Btn label="公钥指纹" tooltip="查看公钥指纹" onPress={() => showKey(m)} />
                  </If>
                  <If when={manager() || isSelf}>
                    <Btn label="重命名" disabled={props.busy} onPress={() => renameDevice(m)} />
                  </If>
                  <If when={manager() && !isSelf}>
                    <Btn
                      label="移除"
                      kind="danger"
                      disabled={props.busy}
                      onPress={() => confirm({
                        title: `移除 ${m.name}`,
                        text: "将撤销其设备组成员资格。本机密码库资料会保留。",
                        ok: "移除设备",
                        danger: true,
                        onConfirm: () => act({ op: "remove", device: m.device }),
                      })}
                    />
                  </If>
                </Row>
              </Row>
            );
          })}
        </Group>
      </View>

      {/* Danger Zone */}
      <View style={{ gap: 7 }}>
        <T size={12} weight="600" color={c().muted}>危险操作</T>
        <Group>
          <OptionRow
            last
            title="退出或解散设备组"
            note="退出仅断开本机双向同步，本机已保存的密码库资料会完整保留。"
          >
            <Row gap={8}>
              <Btn label="退出设备组" disabled={props.busy} onPress={() => exit("leave")} />
              <If when={manager()}>
                <Btn label="解散设备组" kind="danger" disabled={props.busy} onPress={() => exit("disband")} />
              </If>
            </Row>
          </OptionRow>
        </Group>
      </View>
    </If>

    {/* Connection settings when joining (not yet in group state) */}
    <If when={props.group.joining && !props.group.state}>
      <Row><Btn label={connectionSettings() ? "收起连接设置" : "连接设置"} onPress={() => connectionSettings.set(!connectionSettings())} /></Row>
      <If when={connectionSettings()}><Group style={{ gap: 8, paddingVertical: 12 }}>
        <T weight="600">更新中继密码</T>
        <T size={12} color={c().muted}>保存本机使用的服务器访问密码，保留设备组身份。连接验证失败时请修正后重试；这不会修改服务器本身的密码。</T>
        <TextBox masked value={relayPassword()} onChange={v => relayPassword.set(v)} label="新的中继密码" testID="update-relay-password" />
        <Row><Btn label="保存中继密码并重连" disabled={props.busy || !relayPassword()} onPress={() => { act({ op: "update-password", relayPassword: relayPassword() }); relayPassword.set(""); }} /></Row>
      </Group></If>
    </If>
  </View>;
}
