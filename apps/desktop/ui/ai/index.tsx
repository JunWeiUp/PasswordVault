import { pollEvery } from "../polling";
import { desktopCapabilities } from "../native";
import { cleanup, effect, signal, View } from "nsh";
export { AiWorkspacePage } from "./Workspace";
import { Dialog } from "nsh/base";
import { Ai } from "passwordvault/native";
import { Banner, Btn, IconBtn, Row, T, TextBox, Toggle } from "../kit";
import { call, errorText, generatePassword, noteCategories, now, phase, refreshItems, saveNow, settings as vaultSettings, toast, vaultInstance } from "../store";
import { c } from "../theme";
export const status = signal<any>({ settings: {}, pending: [] });
export async function control(r: any) { return JSON.parse(await Ai.control(vaultInstance, JSON.stringify(r))); }
export async function refresh(isActive: () => boolean = () => true) {
  try { const next = await control({ op: "status" }); if (!isActive()) return; status.set(phase() === "unlocked" ? next : { settings: {}, pending: [] }); } catch { if (isActive()) status.set({ settings: {}, pending: [] }); }
}
export async function change(r: any) { try { await control(r); await refresh(); } catch (e) { toast(String(e)); } }
export const cfg = () => status().settings;
export const aiSettings = () => ({ ...vaultSettings(), ...cfg() });
export const aiWritableCategories = (): string[] =>
  Array.isArray(aiSettings().aiAccessNoteWritableCategories)
    ? aiSettings().aiAccessNoteWritableCategories.map((s: any) => String(s).trim().replace(/^\/+|\/+$/g, "")).filter(Boolean)
    : [];
export async function setCategoryAiWritable(cat: string, allow: boolean) {
  const clean = cat.trim().replace(/^\/+|\/+$/g, "");
  if (!clean) return;
  const current = aiWritableCategories();
  const next = allow ? [...new Set([...current, clean])] : current.filter((p) => p !== clean);
  const patch: Record<string, unknown> = { op: "configure", aiAccessNoteWritableCategories: next };
  if (allow && aiSettings().aiAccessNoteAutoWrite !== true) patch.aiAccessNoteAutoWrite = true;
  await change(patch);
  if (allow && !noteCategories().includes(clean)) {
    try {
      await call({ op: "category-add", name: clean });
      const doc = await call<{ settings: Record<string, any> }>({ op: "list", summaries: true });
      vaultSettings.set(doc.settings ?? {});
    } catch {}
  }
  vaultSettings.update((s) => ({
    ...s,
    aiAccessNoteWritableCategories: next,
    ...(allow ? { aiAccessNoteAutoWrite: true } : {}),
  }));
  toast(allow ? `已允许 AI 自动保存「${clean}」目录` : `已关闭「${clean}」目录的 AI 自动保存`);
}
/** Mount exactly once beside the app's other overlay hosts. */
export function AiApprovalHost() {
  if (!desktopCapabilities.ai) return null;
  effect(() => {
    if (phase() !== "unlocked") { Ai.cancelPending(); status.set({ settings: {}, pending: [] }); return; }
    void Ai.start(vaultInstance).then(() => refresh(), (e) => {
      // Another preview instance already serves the fixed AI socket: stay quiet here;
      // the AI settings page reports the service as not running.
      if (!String(e).includes("SocketInUse")) toast("AI 访问服务未能启动，可在设置 → AI 访问中重试。");
    });
    cleanup(pollEvery(500, refresh));
  });
  // Entries an AI client adds go straight to the core; reload the list when the count moves.
  let seenChanges: number | undefined;
  let seenNoteChangeKey: string | undefined;
  effect(() => {
    const n = status().changes;
    if (typeof n !== "number") return;
    if (seenChanges !== undefined && n !== seenChanges && phase() === "unlocked") void refreshItems().catch(() => {});
    seenChanges = n;
  });
  effect(() => {
    const noteChange = status().lastNoteChange;
    if (!noteChange || typeof noteChange !== "object") return;
    const key = `${noteChange.id ?? ""}:${noteChange.unixSeconds ?? ""}:${noteChange.summary ?? ""}`;
    if (seenNoteChangeKey !== undefined && key !== seenNoteChangeKey && phase() === "unlocked") {
      void refreshItems().catch(() => {});
      const actor = noteChange.actor || "AI";
      const title = noteChange.title || "笔记";
      toast(`${actor} 已自动更新「${title}」`);
    }
    seenNoteChangeKey = key;
  });
  const p = () => phase() === "unlocked" ? status().pending[0] : undefined;
  const answer = (allow: boolean, leaseSeconds?: number) => void change({ op: "approve", requestId: p().requestId, allow, ...(leaseSeconds === undefined ? {} : { leaseSeconds }) });
  const create = () => p()?.kind === "create";
  const secret = () => p()?.kind === "secret";
  const reveal = () => p()?.delivery === "reveal";
  const title = () => !secret() ? "允许 AI 访问这个条目？" : p()?.grant ? `允许 AI 访问此条目并读取${aiFieldLabel(p()?.field)}？` : `允许 AI 读取${aiFieldLabel(p()?.field)}？`;
  const line = (label: string, value: any, color?: string) => <Row gap={12} style={{ alignItems: "flex-start" }}><T size={12} color={c().muted} style={{ width: 56 }}>{label}</T><T size={12.5} color={color ?? c().ink} style={{ flex: 1, minWidth: 0 }}>{value}</T></Row>;
  return <If when={p()}><If when={create()} else={<Dialog open onOpenChange={({ open: visible }) => { if (!visible && p()) answer(false); }} backdropStyle={{ backgroundColor: c().backdrop }} style={{ alignSelf: "center", marginTop: 130, width: 520, padding: 24, gap: 14, backgroundColor: c().surface, borderRadius: 14 }}>
    <T size={18} weight="600">{title()}</T>
    <View style={{ gap: 8 }}>
      {line("客户端", p()?.client)}{line("条目", p()?.item)}
      <If when={p()?.purpose}>{line("用途", p()?.purpose)}</If>
      <If when={secret()}>{line("交付", reveal() ? "把明文返回给 AI" : `放到剪贴板，${30} 秒后清除 · AI 看不到内容`, reveal() ? c().orange : c().green)}</If>
      <If when={p()?.grant}>{line("授权", "同时把此条目加入该客户端的可访问列表", c().muted)}</If>
    </View>
    <If when={secret()} else={<Banner tone="info" title="只开放普通字段" style={{ marginBottom: 0 }}>加入后 AI 可以读取此条目的标题、用户名等普通字段；密码等敏感字段仍需逐次确认。</Banner>}>
      <If when={reveal()} else={<Banner tone="ok" title="秘密不会进入 AI 对话" style={{ marginBottom: 0 }}>AI 只会收到“已放到剪贴板”。由你或 AI 粘贴到需要的地方。</Banner>}>
        <Banner tone="warn" title="AI 将看到明文" style={{ marginBottom: 0 }}>内容会进入 AI 客户端上下文，之后撤销权限也无法收回。</Banner>
      </If>
    </If>
    <Row gap={8} wrap>
      <Btn label="拒绝" onPress={() => answer(false)} />
      <View style={{ flex: 1 }} />
      <If when={secret() && p()?.leaseUntilLock}><Btn label="锁定前免确认" tooltip="此客户端在锁定前再次读取该字段无需确认" onPress={() => answer(true, 0)} /></If>
      <If when={secret()}><Btn label={`${p()?.leaseMinutes ?? 15} 分钟内免确认`} tooltip="此客户端在这段时间内再次读取该字段无需确认，可随时结束" onPress={() => answer(true, (p()?.leaseMinutes ?? 15) * 60)} /></If>
      <Btn label={secret() ? "允许一次" : "允许访问"} kind="primary" onPress={() => answer(true)} />
    </Row>
    <T size={10.5} color={c().faint}>请求 {p()?.requestId} · 60 秒未确认将自动拒绝</T>
  </Dialog>}><Each of={[p()]} key={(r: any) => r.requestId}>{(r: any) => <AskUserDialog request={r()} />}</Each></If></If>;
}
/** AI asked for an account the vault lacks: the user fills it in, it is saved here, then returned. */
function AskUserDialog(props: { request: any }) {
  const r = props.request;
  const title = signal(r.item ?? ""), url = signal(r.url ?? ""), username = signal(r.username ?? ""), secret = signal(""), showSecret = signal(false), saving = signal(false);
  const deny = () => void change({ op: "approve", requestId: r.requestId, allow: false });
  const generate = async () => {
    try {
      secret.set(await generatePassword({ length: 24, upper: true, lower: true, digits: true, symbols: true }));
    } catch (e) { toast(errorText(e)); }
  };
  const submit = async () => {
    if (saving() || !title().trim()) return;
    saving.set(true);
    const at = now();
    const item = { id: crypto.randomUUID(), type: "password" as const, title: title().trim(), url: url().trim(), username: username().trim(), password: secret(), note: "", tags: [],
      noteFormat: "plain", isDeleted: false, isFavorite: false, isPinned: false, createdAt: at, updatedAt: at };
    if (await saveNow(item)) await change({ op: "approve", requestId: r.requestId, allow: true, entryId: item.id });
    saving.set(false);
  };
  const reveal = r.delivery === "reveal";
  const field = (label: string, value: () => string, set: (v: string) => void, masked = false) => <View style={{ gap: 4 }}><T size={11.5} color={c().muted}>{label}</T><TextBox label={label} value={value()} onChange={set} masked={masked} /></View>;
  return <Dialog open onOpenChange={({ open: visible }) => { if (!visible) deny(); }} backdropStyle={{ backgroundColor: c().backdrop }} style={{ alignSelf: "center", marginTop: 100, width: 520, padding: 24, gap: 12, backgroundColor: c().surface, borderRadius: 14 }}>
    <T size={18} weight="600">{r.client} 需要一个库里还没有的账号</T>
    <If when={r.purpose}><T size={12.5} color={c().muted}>用途：{r.purpose}</T></If>
    {field("名称", title, v => title.set(v))}
    {field("网址", url, v => url.set(v))}
    {field("用户名", username, v => username.set(v))}
    <View style={{ gap: 4 }}>
      <T size={11.5} color={c().muted}>密码</T>
      <Row gap={6}>
        <View style={{ flex: 1 }}>
          <TextBox label="密码" value={secret()} onChange={v => secret.set(v)} masked={!showSecret()} />
        </View>
        <IconBtn icon="eye" label={showSecret() ? "隐藏密码" : "显示密码"} tint={showSecret() ? c().blue : c().muted} onPress={() => showSecret.update(s => !s)} />
        <Btn label="生成" icon="wand" onPress={() => void generate()} />
      </Row>
    </View>
    <Banner tone={reveal ? "warn" : "ok"} title={reveal ? "AI 将看到密码明文" : "密码只放到剪贴板"} style={{ marginBottom: 0 }}>保存到 PasswordVault 并允许该客户端访问此条目。{reveal ? "明文会进入 AI 对话，无法收回。" : "30 秒后清除，AI 看不到明文。"}</Banner>
    <Row gap={8}><Btn label="取消" onPress={deny} /><View style={{ flex: 1 }} /><Btn label={saving() ? "正在保存…" : reveal ? "保存并返回明文" : "保存并复制密码"} kind="primary" disabled={saving() || !title().trim()} onPress={() => void submit()} /></Row>
    <T size={10.5} color={c().faint}>请求 {r.requestId} · 3 分钟未提交将自动取消</T>
  </Dialog>;
}
const FIELD_LABELS: Record<string, string> = { password: "密码", token: "令牌", privateKey: "私钥", nodeLink: "节点链接", notes: "备注", phone: "手机", address1: "地址", address2: "地址第二行", postalCode: "邮编", number: "卡号", securityCode: "安全码" };
export const aiFieldLabel = (field?: string) => !field ? "敏感字段" : field.startsWith("custom:") ? "自定义敏感字段" : field.startsWith("service:") ? "服务路径" : field.startsWith("command:") ? "私密命令" : FIELD_LABELS[field] ?? field;
/** Explicit classification, never inferred from extensions. Mount beside file metadata. */
export function AiFileAccess(props: { entryId: string; fileId: string; name: string }) {
  return <Toggle title={`标记为普通资料：${props.name}`} note="允许读取后，内容可能进入 AI 上下文；请确认文件不含密码、令牌、节点链接或私钥。"
    checked={cfg().aiAccessOrdinaryFiles?.[props.entryId]?.[props.fileId] === true}
    onChange={v => void change({ op: "configure", aiAccessOrdinaryFiles: { ...cfg().aiAccessOrdinaryFiles, [props.entryId]: { ...cfg().aiAccessOrdinaryFiles?.[props.entryId], [props.fileId]: v } } })} />;
}
