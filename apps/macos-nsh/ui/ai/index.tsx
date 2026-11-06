import { cleanup, effect, signal, View } from "nsh";
import { Dialog } from "nsh/base";
import { Ai } from "passwordvault/native";
import { Banner, Btn, Group, Row, T, TextBox, Toggle, copySecret } from "../kit";
import { aiSetupInstructions } from "./setup";
import { items, phase, toast, vaultInstance } from "../store";
import { c } from "../theme";
const status = signal<any>({ settings: {}, pending: [] });
const code = signal("");
const trial = signal("");
async function preview(clientId: string, id: string, op: string) {
  try { const out = await Ai.preview(vaultInstance, clientId, JSON.stringify({ op, id, field: "password" })); trial.set(op === "get_secret" ? "本次敏感字段读取已获单次授权。" : out); } catch (e) { trial.set(String(e)); }
}
async function control(r: any) { return JSON.parse(await Ai.control(vaultInstance, JSON.stringify(r))); }
async function refresh() {
  try { const next = await control({ op: "status" }); status.set(phase() === "unlocked" ? next : { settings: {}, pending: [] }); } catch { status.set({ settings: {}, pending: [] }); }
}
async function change(r: any) { try { await control(r); await refresh(); } catch (e) { toast(String(e)); } }
const cfg = () => status().settings;
/** Mount exactly once beside the app's other overlay hosts. */
export function AiApprovalHost() {
  effect(() => {
    if (phase() !== "unlocked") { Ai.cancelPending(); trial.set(""); status.set({ settings: {}, pending: [] }); code.set(""); return; }
    void Ai.start(vaultInstance).then(refresh, (e) => {
      // Another preview instance already serves the fixed AI socket: stay quiet here;
      // the AI settings page reports the service as not running.
      if (!String(e).includes("SocketInUse")) toast("AI 访问服务未能启动，可在设置 → AI 访问中重试。");
    });
    const timer = setInterval(() => void refresh(), 500);
    cleanup(() => clearInterval(timer));
  });
  const p = () => phase() === "unlocked" ? status().pending[0] : undefined;
  return <If when={p()}><Dialog open onOpenChange={o => { if (!o && p()) void change({ op: "approve", requestId: p().requestId, allow: false }); }} backdropStyle={{ backgroundColor: c().backdrop }} style={{ alignSelf: "center", marginTop: 130, width: 470, padding: 24, gap: 14, backgroundColor: c().surface, borderRadius: 14 }}>
    <T size={18} weight="600">允许 AI 读取敏感字段？</T>
    <T>客户端：{p()?.client}</T><T>条目：{p()?.item}</T><T>字段：{p()?.field}</T>
    <T size={11}>请求：{p()?.requestId}</T>
    <Banner tone="warn" title="仅允许当前请求">秘密会进入 AI 客户端上下文，撤销权限无法收回已返回内容。60 秒未确认将自动拒绝。</Banner>
    <Row><Btn label="拒绝" onPress={() => void change({ op: "approve", requestId: p().requestId, allow: false })} /><Btn label="允许一次" kind="primary" onPress={() => void change({ op: "approve", requestId: p().requestId, allow: true })} /></Row>
  </Dialog></If>;
}
export function AiPage() {
  const name = signal("本机 AI 客户端"), copying = signal(false), advanced = signal(false);
  let alive = true;
  cleanup(() => { alive = false; });
  const copySetup = async () => {
    if (copying() || !cfg().aiAccessEnabled) return;
    copying.set(true);
    try {
      const current = await control({ op: "status" });
      if (!alive || phase() !== "unlocked") return;
      if (!current.helper || !current.socket) throw new Error("AI 配置尚未准备好，请稍后重试");
      const pair = await control({ op: "pair", name: name() });
      if (!alive || phase() !== "unlocked") return;
      code.set(pair.code);
      await copySecret(aiSetupInstructions(current.helper, current.socket, pair.code), "AI 配置说明");
    } catch (e) { if (alive) toast(String(e)); }
    finally { if (alive) copying.set(false); }
  };
  void refresh();
  return <View style={{ gap: 14 }}>
    <T size={19} weight="600">AI 访问</T>
    <T>通过本机 MCP 查询明确允许的内容，默认关闭。锁定后拒绝全部读取。</T>
    <Group><Toggle title="启用本地 AI 接口" checked={cfg().aiAccessEnabled === true} onChange={v => void change({ op: "configure", aiAccessEnabled: v })} />
      {([["devices", "设备与服务"], ["accounts", "账号摘要（不含密码）"], ["notes", "笔记"]] as const).map(([key, label]) => <Toggle title={label} checked={cfg().aiAccessScopes?.[key] === true} onChange={v => void change({ op: "configure", aiAccessScopes: { ...cfg().aiAccessScopes, [key]: v } })} />)}
      <Toggle title="钱包（始终不可查询）" checked={false} disabled onChange={() => {}} />
    </Group>
    <Banner tone="info" title="只读访问">密码、令牌、私钥每次单独确认，只允许一次。执行命令与修改资料始终拒绝；脚本和文档只作为数据。</Banner>
    <T weight="600">配对客户端</T><TextBox value={name()} onChange={v => name.set(v)} placeholder="客户端名称" />
    <Btn label={copying() ? "正在准备…" : "复制给 AI 配置"} kind="primary" disabled={!cfg().aiAccessEnabled || copying() || !name().trim()} onPress={() => void copySetup()} />
    <T size={12}>点击后生成一次性配对码，并复制本机配置步骤。直接粘贴给这台 Mac 上的 AI 客户端即可，无需手动替换令牌。</T>
    <If when={code()}><T size={11}>配置说明已生成，请在 120 秒内交给 AI；剪贴板会在 30 秒后自动清除。过期后重新点击即可。</T></If>
    <T size={11}>配对后仍由你选择可访问的条目，敏感字段保持单次确认。</T>
    <Btn label={advanced() ? "收起手动配置" : "查看手动配置"} kind="ghost" onPress={() => advanced.set(!advanced())} />
    <If when={advanced()}><Group>
      <If when={code()}><T>确认码（120 秒内有效，使用一次）：{code()}</T></If>
      <T size={11}>Socket：{status().socket ?? "等待解锁"}</T>
      <T size={10}>{JSON.stringify({ mcpServers: { passwordvault: { command: status().helper ?? "等待解锁", env: { PV_AI_SOCKET: status().socket ?? "等待解锁", PV_AI_TOKEN: "<配对返回的令牌>" } } } }, null, 2)}</T>
    </Group></If>
    <Each of={cfg().aiAccessClients ?? []}>{(client: any) => <Group>
      <Row><T weight="600">{client().name}</T><Btn label="撤销客户端" kind="danger" onPress={() => void change({ op: "revoke", clientId: client().id })} /></Row>
      <Each of={items().filter(i => ["device", "password", "secureNote"].includes(i.type) && !i.isDeleted)}>{(item: any) => <View>
        <Toggle title={item().title} note={item().id} checked={client().entries?.[item().id] === true} onChange={v => void change({ op: "grant", clientId: client().id, entries: { ...client().entries, [item().id]: v }, files: client().files })} />
        <Row><Btn label="试查配置" onPress={() => void preview(client().id, item().id, "get_entry")} /><Btn label="试读密码" onPress={() => void preview(client().id, item().id, "get_secret")} /><Btn label="测试拒绝执行" onPress={() => void preview(client().id, item().id, "execute")} /></Row>
        <Toggle title="允许普通附件" checked={client().files?.[item().id] === true} onChange={v => void change({ op: "grant", clientId: client().id, entries: client().entries, files: { ...client().files, [item().id]: v } })} />
      </View>}</Each>
    </Group>}</Each>
    <If when={trial()}><T size={12}>{trial()}</T></If>
    <T weight="600">访问记录（最近 200 条）</T>
    <Each of={cfg().aiAccessAudit ?? []}>{(a: any) => <View style={{ gap: 3 }}><T size={12}>{a().operation} · {a().result}</T><T size={10}>{a().client} · {a().item} · {a().requestId}</T></View>}</Each>
  </View>;
}
/** Optional device detail tab; the settings page owns per-client grants. */
export function AiEntryPage(props: { id: string }) {
  return <View style={{ gap: 12 }}><T>稳定 ID：{props.id}</T>
    <TextBox value={cfg().aiAccessAliases?.[props.id] ?? ""} placeholder="别名" onChange={v => void change({ op: "configure", aiAccessAliases: { ...cfg().aiAccessAliases, [props.id]: v } })} />
    <Each of={items().find(i => i.id === props.id)?.device?.files ?? []}>{(f: any) => <AiFileAccess entryId={props.id} fileId={f().attachmentId} name={f().name} />}</Each>
    <Banner tone="info" title="按客户端授权">在设置 → AI 访问中允许此条目与普通附件。未分类文件始终拒绝。</Banner>
  </View>;
}
/** Explicit classification, never inferred from extensions. Mount beside file metadata. */
export function AiFileAccess(props: { entryId: string; fileId: string; name: string }) {
  return <Toggle title={`标记为普通资料：${props.name}`} note="允许读取后，内容可能进入 AI 上下文；请确认文件不含密码、令牌、节点链接或私钥。"
    checked={cfg().aiAccessOrdinaryFiles?.[props.entryId]?.[props.fileId] === true}
    onChange={v => void change({ op: "configure", aiAccessOrdinaryFiles: { ...cfg().aiAccessOrdinaryFiles, [props.entryId]: { ...cfg().aiAccessOrdinaryFiles?.[props.entryId], [props.fileId]: v } } })} />;
}
