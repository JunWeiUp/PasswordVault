// Tools → AI 访问: status, trial requests, leases, scopes, paired clients and audit in one page.
import { cleanup, signal, Scroll, View } from "nsh";
import { Ai } from "passwordvault/native";
import { desktopCapabilities } from "../native";
import { Banner, Btn, Card, Group, IconTile, ListRow, Pill, Row, SheetFooter, SheetTitle, T, TextBox, Toggle, confirm, copySecret, openSheet } from "../kit";
import { Icon } from "../icons";
import { errorText, items, onLock, phase, toast, vaultInstance, TYPE_NAME, type Item } from "../store";
import { c } from "../theme";
import { ToolHeader } from "../Tools";
import { aiSetupInstructions } from "./setup";
import { aiFieldLabel, cfg, change, code, control, refresh, status } from "./index";

const AI_ERRORS: Record<string, string> = {
  ApprovalDenied: "已拒绝本次读取", ApprovalTimeout: "60 秒未确认，已自动拒绝", Busy: "待审批请求过多，请稍后再试",
  DeniedField: "该字段不允许 AI 读取", Disabled: "本机 AI 接口未启用", EntryChanged: "条目在审批期间已修改，请重新请求",
  Locked: "密码库已锁定", ReadOnlyUnsupportedOperation: "执行请求已拒绝 · PasswordVault 只提供只读资料",
  Unsupported: "执行请求已拒绝 · PasswordVault 只提供只读资料", RevokedOrUnknownClient: "客户端已撤销或不存在",
  UnknownClient: "客户端已撤销或不存在", UnscopedOrMissing: "条目不存在，或所属类别未开启",
};
export const aiError = (e: unknown) => AI_ERRORS[String(e).replace(/^Error:\s*/, "")] ?? errorText(e);
const AI_RESULTS: Record<string, string> = { Allowed: "已允许", AllowedByLease: "免确认放行", ApprovalDenied: "已拒绝", ApprovalTimeout: "超时拒绝", Locked: "锁定拒绝", DeferredAuditFlushed: "解锁后补记" };
const AI_OPS: Record<string, string> = { search_entries: "搜索摘要", get_entry: "读取条目", get_secret: "敏感字段", list_files: "列出附件", read_file: "读取附件", unsupported: "执行请求", unlock: "审计" };
/** Item types each scope exposes; wallets (crypto) are never available. */
const SCOPE_TYPES: Record<string, string[]> = { accounts: ["password"], devices: ["device"], notes: ["secureNote"], profiles: ["identity", "creditCard"] };
const ICON: Record<string, any> = { password: "key", device: "server", secureNote: "note", identity: "user", creditCard: "wallet" };

const busy = signal("");
const clients = (): any[] => cfg().aiAccessClients ?? [];
const enabled = () => cfg().aiAccessEnabled === true;
const scopeOn = (key: string) => cfg().aiAccessScopes?.[key] === true;
const titleOf = (id: string) => items().find(item => item.id === id)?.title || "";
const clientName = (id: string) => clients().find(entry => entry.id === id)?.name ?? (id === "app" ? "本机" : "未知客户端");

/** Sends one request as a paired client so it follows the same policy, approval and audit as MCP. */
async function trial(key: string, request: Record<string, unknown>, ok: (out: any) => string) {
  if (busy()) return;
  if (!enabled()) { toast("请先启用本机 AI 接口"); return; }
  const id = request.id as string | undefined;
  const client = clients().find(entry => id && entry.entries?.[id]) ?? clients()[0];
  if (!client) { toast("请先配对客户端"); return; }
  busy.set(key);
  try { toast(ok(JSON.parse(await Ai.preview(vaultInstance, client.id, JSON.stringify(request))))); }
  catch (e) { if (phase() === "unlocked") toast(aiError(e)); }
  finally { busy.set(""); void refresh(); }
}
// Trial reads use the default clipboard delivery, exactly like an MCP client that does not ask to reveal.
export const requestSecret = (item: Item, field: string, purpose: string) =>
  trial(`${item.id}:${field}`, { op: "get_secret", id: item.id, field, purpose }, out => out.delivered === "clipboard" ? `${out.approval === "lease" ? "免确认授权中 · " : ""}已放到剪贴板，${out.clearsAfterSeconds ?? 30} 秒后清除` : "已允许 · 明文已返回给客户端");

function relativeTime(seconds: number) {
  const diff = Math.max(0, Date.now() / 1000 - seconds);
  if (diff < 60) return "刚刚";
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} 小时前`;
  return new Date(seconds * 1000).toLocaleDateString();
}
function Divided(props: { rows: any[]; render: (row: any, index: number) => any; gap?: number }) {
  return <View>{props.rows.map((row, index) => <View style={{ paddingVertical: props.gap ?? 8, borderBottomWidth: index === props.rows.length - 1 ? 0 : 1, borderBottomColor: c().line2 }}>{props.render(row, index)}</View>)}</View>;
}
function ScopeSwitch(props: { title: string; note: string; scope: string }) {
  return <Toggle title={props.title} note={props.note} checked={scopeOn(props.scope)} disabled={!enabled()} onChange={v => void change({ op: "configure", aiAccessScopes: { ...cfg().aiAccessScopes, [props.scope]: v } })} />;
}
function FixedScope(props: { title: string; note: string; tone: "orange" | "red"; pill: string; last?: boolean }) {
  return <Row gap={10} style={{ paddingVertical: 11, borderBottomWidth: props.last ? 0 : 1, borderBottomColor: c().line2 }}>
    <View style={{ flex: 1, minWidth: 0, gap: 2 }}><T size={13}>{props.title}</T><T size={11} color={c().muted}>{props.note}</T></View>
    <Pill tone={props.tone}>{props.pill}</Pill>
  </Row>;
}

function PairSheet(props: { close: () => void }) {
  const name = signal("本机 AI 客户端"), copying = signal(false), advanced = signal(false);
  let alive = true;
  cleanup(() => { alive = false; });
  cleanup(onLock(props.close));
  const copySetup = async () => {
    if (copying() || !enabled()) return;
    copying.set(true);
    try {
      const current = await control({ op: "status" });
      if (!alive || phase() !== "unlocked") return;
      if (!current.helper || !current.socket) throw new Error("AI 服务尚未就绪，请稍后重试");
      const pair = await control({ op: "pair", name: name() });
      if (!alive || phase() !== "unlocked") return;
      code.set(pair.code);
      await copySecret(aiSetupInstructions(current.helper, current.socket, pair.code), "AI 配置说明");
    } catch (e) { if (alive) toast(aiError(e)); }
    finally { if (alive) copying.set(false); }
  };
  return <View style={{ gap: 12 }}>
    <SheetTitle title="配对 AI 客户端" text="生成一次性配对码并复制本机配置步骤，粘贴给这台 Mac 上的 AI 客户端即可。配对不会授予任何条目。" />
    <View style={{ gap: 6 }}><T size={11.5} color={c().muted}>客户端名称</T><TextBox label="客户端名称" value={name()} onChange={v => name.set(v)} placeholder="例如 Claude Code" /></View>
    <If when={code()}><Banner tone="ok" title="配置说明已复制" style={{ marginBottom: 0 }}>请在 120 秒内交给 AI；剪贴板会在 30 秒后自动清除。过期后重新生成即可。</Banner></If>
    <Btn label={advanced() ? "收起手动配置" : "查看手动配置"} kind="ghost" onPress={() => advanced.set(!advanced())} />
    <If when={advanced()}><View style={{ gap: 6, backgroundColor: c().soft2, borderRadius: 8, padding: 10 }}>
      <If when={code()}><T size={12}>确认码（120 秒内有效，使用一次）：<T mono size={12} selectable>{code()}</T></T></If>
      <T mono size={10.5} selectable>{JSON.stringify({ mcpServers: { passwordvault: { command: status().helper ?? "等待解锁", env: { PV_AI_SOCKET: status().socket ?? "等待解锁", PV_AI_TOKEN: "<配对返回的令牌>" } } } }, null, 2)}</T>
    </View></If>
    <SheetFooter><Btn label="关闭" onPress={props.close} /><Btn label={copying() ? "正在准备…" : code() ? "重新生成" : "复制给 AI"} icon="copy" kind="primary" disabled={!enabled() || copying() || !name().trim()} onPress={() => void copySetup()} /></SheetFooter>
  </View>;
}

function GrantSheet(props: { client: any; close: () => void }) {
  const query = signal("");
  cleanup(onLock(props.close));
  const live = () => clients().find(entry => entry.id === props.client.id) ?? props.client;
  const types = () => Object.entries(SCOPE_TYPES).filter(([scope]) => scopeOn(scope)).flatMap(([, list]) => list);
  const candidates = () => {
    const q = query().trim().toLowerCase();
    return items().filter(item => !item.isDeleted && types().includes(item.type) && live().entries?.[item.id] !== true && (!q || `${item.title} ${item.username ?? ""}`.toLowerCase().includes(q))).slice(0, 60);
  };
  const add = (item: Item) => void change({ op: "grant", clientId: live().id, entries: { ...live().entries, [item.id]: true }, files: live().files ?? {} });
  return <View style={{ gap: 12 }}>
    <SheetTitle title={`允许 ${props.client.name} 访问条目`} text="只列出已开启类别中尚未授权的条目。AI 首次请求未授权条目时，也会弹窗询问。" />
    <TextBox label="搜索条目" placeholder="搜索标题或用户名…" value={query()} onChange={v => query.set(v)} />
    <Scroll style={{ maxHeight: 360 }}>
      <If when={candidates().length > 0} else={<T size={12} color={c().faint}>{types().length ? "没有可添加的条目" : "请先开启至少一个类别"}</T>}>
        <Divided rows={candidates()} render={(item: Item) => <Row gap={10}>
          <IconTile name={ICON[item.type] ?? "key"} size={28} />
          <View style={{ flex: 1, minWidth: 0 }}><T size={12.5} weight="500" lines={1}>{item.title || "未命名"}</T><T size={11} color={c().muted}>{TYPE_NAME[item.type]}</T></View>
          <Btn label="允许" icon="plus" onPress={() => add(item)} />
        </Row>} />
      </If>
    </Scroll>
    <SheetFooter><Btn label="完成" kind="primary" onPress={props.close} /></SheetFooter>
  </View>;
}

function ClientCard(props: { client: any }) {
  const client = () => clients().find(entry => entry.id === props.client.id) ?? props.client;
  const granted = () => Object.entries(client().entries ?? {}).filter(([, on]) => on).map(([id]) => items().find(item => item.id === id)).filter((item): item is Item => !!item && !item.isDeleted);
  const grant = (entries: any, files: any) => void change({ op: "grant", clientId: client().id, entries, files });
  return <Card title={client().name} note={`已授权 ${granted().length} 个条目 · 敏感字段仍需确认`} right={<Row gap={6}>
    <Btn label="添加条目…" icon="plus" onPress={() => openSheet({ width: 520, render: close => <GrantSheet client={client()} close={close} /> })} />
    <Btn label="撤销" kind="danger" onPress={() => confirm({ title: `撤销 ${client().name}？`, text: "该客户端的令牌立即失效，已授权的条目也会一并移除。已返回给 AI 的内容无法收回。", ok: "撤销客户端", danger: true, onConfirm: () => void change({ op: "revoke", clientId: client().id }) })} />
  </Row>}>
    <If when={granted().length > 0} else={<T size={12} color={c().faint}>还没有授权条目。AI 首次请求时会询问你，也可以点击“添加条目…”预先允许。</T>}>
      <Divided rows={granted()} render={(item: Item) => <Row gap={10}>
        <IconTile name={ICON[item.type] ?? "key"} size={28} />
        <View style={{ flex: 1, minWidth: 0 }}><T size={12.5} weight="500" lines={1}>{item.title || "未命名"}</T><T size={11} color={c().muted}>{TYPE_NAME[item.type]}{client().files?.[item.id] ? " · 允许普通附件" : ""}</T></View>
        <If when={item.type === "device" || item.type === "secureNote"}><Btn label={client().files?.[item.id] ? "禁止附件" : "允许附件"} kind="ghost" tooltip="仅限已标记为普通资料的附件" onPress={() => grant(client().entries, { ...client().files, [item.id]: !client().files?.[item.id] })} /></If>
        <Btn label="移除" kind="ghost" onPress={() => grant({ ...client().entries, [item.id]: false }, { ...client().files, [item.id]: false })} />
      </Row>} />
    </If>
  </Card>;
}

export function AiWorkspacePage() {
  const width = signal(900), allAudit = signal(false);
  void refresh();
  const body = () => {
    const client = () => clients()[0];
    const pick = (type: string) => items().find(item => item.type === type && !item.isDeleted && client()?.entries?.[item.id]) ?? items().find(item => item.type === type && !item.isDeleted);
    const account = () => pick("password"), identity = () => pick("identity");
    const ready = () => enabled() && !!client();
    const audit = () => (cfg().aiAccessAudit ?? []).filter((row: any) => row.operation !== "unlock").slice(0, allAudit() ? 50 : 5);
    const leases = (): any[] => status().leases ?? [];
    const pair = () => openSheet({ width: 520, render: close => <PairSheet close={close} /> });
    const endLeases = (body: Record<string, unknown> = {}) => void control({ op: "end_leases", ...body }).then(() => refresh(), e => toast(aiError(e)));
    const hero = <View style={{ flexDirection: "row", gap: 16, alignItems: "flex-start", padding: 18, borderRadius: 12, borderWidth: 1, borderColor: c().blueLine, backgroundColor: c().blueSoft }}>
      <IconTile name="spark" size={44} solid />
      <View style={{ flex: 1, minWidth: 0, gap: 6 }}>
        <Row gap={6}><View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: enabled() ? c().green : c().faint }} /><T size={11.5} color={enabled() ? c().green : c().muted}>{enabled() ? "本机 MCP 已启用 · 锁定后停止读取" : "本机 MCP 未启用"}</T></Row>
        <T size={19} weight="600">让 AI 找到需要的资料</T>
        <T size={12} color={c().ink2}>AI 先读取摘要；需要密码、证件号等敏感字段时由你确认，默认放到剪贴板，AI 看不到明文，也可以选择 15 分钟内免确认。PasswordVault 不执行命令，也不会替 AI 修改资料。</T>
        <Row gap={10} style={{ marginTop: 6 }}><Icon name="shield" size={16} tint={c().blue} /><View style={{ flex: 1, minWidth: 0 }}><T size={12} weight="600">{clients().length ? `${clients().length} 个已配对客户端` : "暂无已配对客户端"}</T><T size={11} color={c().muted}>{clients().length ? clients().map(entry => entry.name).join("、") : "配对后，AI 首次请求条目时由你确认"}</T></View></Row>
      </View>
      <View style={{ width: 128, gap: 8, alignItems: "stretch" }}>
        <Btn label={enabled() ? "停用接口" : "启用接口"} kind={enabled() ? "default" : "primary"} onPress={() => void change({ op: "configure", aiAccessEnabled: !enabled() })} />
        <Btn label="配对客户端" icon="plus" kind={enabled() ? "primary" : "default"} disabled={!enabled()} onPress={pair} />
      </View>
    </View>;
    const leaseCard = <If when={leases().length > 0}><Card title="免确认授权" note="只保存在内存中，锁定、修改 AI 设置或到期后自动结束。" right={<Btn label="全部结束" kind="ghost" onPress={() => endLeases()} />}>
      <Divided rows={leases()} render={(lease: any) => <Row gap={10}>
        <IconTile name="clock" />
        <View style={{ flex: 1, minWidth: 0, gap: 2 }}><T size={12.5} weight="500" lines={1}>{titleOf(lease.entryId) || "条目"} · {aiFieldLabel(lease.field)}</T><T size={11} color={c().muted}>{clientName(lease.client)} · {lease.reveal ? "可返回明文" : "仅剪贴板"} · {lease.secondsLeft == null ? "锁定前有效" : `剩余 ${Math.max(1, Math.ceil(lease.secondsLeft / 60))} 分钟`}</T></View>
        <Btn label="结束" onPress={() => endLeases({ entryId: lease.entryId, field: lease.field })} />
      </Row>} />
    </Card></If>;
    const requests = <Card title="试发请求" note="以已配对客户端的身份发出，弹出与真实 MCP 请求相同的审批。">
      <View style={{ gap: 8 }}>
        <ListRow icon="key" title={account() ? `请求 ${account()!.title || "账号"} 密码` : "请求账号密码"} note={account() ? "放到剪贴板 · 可选 15 分钟免确认" : "还没有账号条目"} disabled={!ready() || !account()} busy={busy() === `${account()?.id}:password`} onPress={() => void requestSecret(account()!, "password", "登录当前网页")} />
        <ListRow icon="user" title="请求身份信息手机" note={identity() ? "低敏感字段 · 可选锁定前免确认" : "还没有身份信息条目"} disabled={!ready() || !identity()} busy={busy() === `${identity()?.id}:phone`} onPress={() => void requestSecret(identity()!, "phone", "填写联系方式表单")} />
        <ListRow icon="search" title="试查普通字段" note="搜索已授权条目的摘要" disabled={!ready()} busy={busy() === "search"} onPress={() => void trial("search", { op: "search_entries", query: "" }, out => `试查返回 ${Array.isArray(out) ? out.length : 0} 条已授权摘要`)} />
        <ListRow icon="tools" title="测试执行请求" note="始终拒绝 · 脚本只作为资料" disabled={!ready()} busy={busy() === "execute"} onPress={() => void trial("execute", { op: "execute", id: account()?.id ?? "" }, () => "执行请求未被拒绝，请检查 AI 设置")} />
      </View>
      <If when={!ready()}><T size={11} color={c().muted}>{enabled() ? "配对客户端后即可试发请求。" : "启用本机接口并配对客户端后即可试发请求。"}</T></If>
    </Card>;
    const recent = <Card title="最近访问" note="记录不包含查询文本、返回内容或秘密。" right={<If when={(cfg().aiAccessAudit ?? []).length > 5}><Btn label={allAudit() ? "收起" : "查看更多"} kind="ghost" onPress={() => allAudit.set(!allAudit())} /></If>}>
      <If when={audit().length > 0} else={<T size={12} color={c().faint}>暂无访问记录</T>}>
        <Divided rows={audit()} render={(row: any) => <Row gap={10} style={{ alignItems: "flex-start" }}>
          <View style={{ width: 7, height: 7, borderRadius: 4, marginTop: 5, backgroundColor: row.result === "Allowed" || row.result === "AllowedByLease" ? c().green : c().orange }} />
          <View style={{ flex: 1, minWidth: 0, gap: 2 }}><T size={12} weight="500">{AI_OPS[row.operation] ?? row.operation} · {AI_RESULTS[row.result] ?? "已拒绝"}</T><T size={11} color={c().muted} lines={1}>{[clientName(row.client), titleOf(row.item), relativeTime(row.unixSeconds)].filter(Boolean).join(" · ")}</T></View>
        </Row>} />
      </If>
    </Card>;
    const scope = <Card title="访问范围" note={enabled() ? "关闭的类别不会出现在搜索中，也不会弹窗询问。" : "启用接口后可设置。"}>
      <View>
        <ScopeSwitch title="账号摘要" note="标题、网站、用户名" scope="accounts" />
        <ScopeSwitch title="身份与银行卡" note="普通字段可查询，敏感字段逐次确认" scope="profiles" />
        <ScopeSwitch title="设备普通字段" note="主机、端口、服务名称和别名" scope="devices" />
        <ScopeSwitch title="笔记" note="授权后可读取正文" scope="notes" />
        <FixedScope title="密码、证件号和卡号" note="默认放到剪贴板；可一次或 15 分钟内免确认" tone="orange" pill="按需确认" />
        <FixedScope title="钱包、助记词和私钥" note="当前 MCP 运行时不开放" tone="red" pill="不可查询" last />
      </View>
    </Card>;
    const tools = <Card title="可用 MCP 工具" note="配对只建立本机连接，不授予任何条目权限。">
      <View style={{ backgroundColor: c().soft2, borderRadius: 8, borderWidth: 1, borderColor: c().line, padding: 10, gap: 4 }}>
        {[["search_entries", "搜索已授权摘要"], ["get_entry", "读取普通字段"], ["get_secret", "请求敏感字段（默认剪贴板）"], ["read_file", "读取已允许的附件"]].map(([name, text]) => <Row gap={8}><T mono size={11.5} style={{ width: 110 }}>{name}</T><T size={11} color={c().muted} style={{ flex: 1 }}>{text}</T></Row>)}
      </View>
    </Card>;
    const clientCards = <Each of={clients()} key={(client: any) => client.id}>{(client: any) => <ClientCard client={client()} />}</Each>;
    return <View onLayout={e => width.set(e.bounds.size.width)} style={{ gap: 14, maxWidth: 1080 }}>
      {hero}
      <If when={width() >= 760} else={<View style={{ gap: 14 }}>{leaseCard}{requests}{scope}{clientCards}{recent}{tools}</View>}>
        <Row gap={14} style={{ alignItems: "flex-start" }}>
          <View style={{ flex: 1, minWidth: 0, gap: 14 }}>{leaseCard}{requests}{clientCards}{recent}</View>
          <View style={{ width: 300, gap: 14 }}>{scope}{tools}</View>
        </Row>
      </If>
    </View>;
  };
  return <View style={{ flex: 1, backgroundColor: c().surface }}>
    <ToolHeader title="AI 访问" />
    <Scroll style={{ flex: 1 }} contentStyle={{ paddingHorizontal: 48, paddingTop: 40, paddingBottom: 40 }}>
      <T size={24} weight="600">AI 访问</T>
      <T color={c().muted} style={{ marginTop: 6, marginBottom: 22 }}>通过本机 MCP 让 AI 查询明确允许的资料。默认关闭，锁定后拒绝全部读取。</T>
      <If when={desktopCapabilities.ai} else={<Banner tone="info" title="此平台暂未开放 AI 访问" style={{ marginBottom: 0 }}>预览版暂不支持 AI 客户端访问密码库。</Banner>}>{body()}</If>
    </Scroll>
  </View>;
}
