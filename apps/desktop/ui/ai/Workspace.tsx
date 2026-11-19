// AI 访问: Option A scope-first policy (ordinary fields readable directly,
// only passwords/keys require approval), paired clients management, writable note categories,
// asset archiving/reading, optional per-entry exclusions, and audit log.
import { cleanup, signal, Scroll, View } from "nsh";
import { Ai } from "passwordvault/native";
import { desktopCapabilities } from "../native";
import { Banner, Btn, Card, IconBtn, IconTile, ListRow, Pill, Row, SheetFooter, SheetTitle, T, TextBox, Toggle, copySecret, openSheet } from "../kit";
import { Icon } from "../icons";
import { items, noteCategories, onLock, phase, settings as vaultSettings, toast, vaultInstance, TYPE_NAME, type Item } from "../store";
import { c } from "../theme";
import { ToolHeader } from "../Tools";
import { AI_OPS, AI_RESULTS, aiError, relativeAuditTime } from "../api/aiAccess";
import { buildAiClientViews } from "../api/aiClients";
import { MCP_TOOLS } from "../api/mcpTools";
import { aiSetupInstructions } from "./setup";
import { aiFieldLabel, aiSettings, aiWritableCategories, cfg, change, control, refresh, setCategoryAiWritable, status } from "./index";
import {
  HeroClientStrip,
  PairedClientsCard,
  auditClientId,
  clientFilter,
  clientNotesMap,
  expandedClientId,
  openClientsManagerSheet,
  saveClientNote,
} from "./ClientsManager";

export { aiError };
const ICON: Record<string, any> = { password: "key", device: "server", secureNote: "note", identity: "user", creditCard: "wallet" };

const busy = signal("");
const clients = (): any[] => cfg().aiAccessClients ?? [];
const enabled = () => cfg().aiAccessEnabled === true;
const scopeOn = (key: string) => cfg().aiAccessScopes?.[key] === true;
const noteAssetsOn = () => scopeOn("notes") && cfg().aiAccessScopes?.noteAssets !== false;
const excludedMap = (): Record<string, boolean> => cfg().aiAccessExcludedEntries ?? {};
const excludedCount = () => Object.values(excludedMap()).filter(Boolean).length;
const titleOf = (id: string) => items().find(item => item.id === id)?.title || "";
const clientById = (id: string) => clients().find(entry => entry.id === id);
const clientName = (id: string) => clientById(id)?.name ?? (id === "app" ? "本机" : "未知客户端");

/** Sends one request as a paired active client so it follows the same policy, approval and audit as MCP. */
async function trial(key: string, request: Record<string, unknown>, ok: (out: any) => string) {
  if (busy()) return;
  if (!enabled()) { toast("请先启用本机 AI 接口"); return; }
  const client = clients().find(entry => entry.paused !== true) ?? clients()[0];
  if (!client) { toast("请先配对客户端"); return; }
  busy.set(key);
  try { toast(ok(JSON.parse(await Ai.preview(vaultInstance, client.id, JSON.stringify(request))))); }
  catch (e) { if (phase() === "unlocked") toast(aiError(e)); }
  finally { busy.set(""); void refresh(); }
}
// Trial reads use the default clipboard delivery, exactly like an MCP client that does not ask to reveal.
export const requestSecret = (item: Item, field: string, purpose: string) =>
  trial(`${item.id}:${field}`, { op: "get_secret", id: item.id, field, purpose }, out => out.delivered === "clipboard" ? `${out.approval === "lease" ? "免确认授权中 · " : ""}已放到剪贴板，${out.clearsAfterSeconds ?? 30} 秒后清除` : "已允许 · 明文已返回给客户端");
function Divided(props: { rows: any[]; render: (row: any, index: number) => any; gap?: number }) {
  return <View>{props.rows.map((row, index) => <View style={{ paddingVertical: props.gap ?? 8, borderBottomWidth: index === props.rows.length - 1 ? 0 : 1, borderBottomColor: c().line2 }}>{props.render(row, index)}</View>)}</View>;
}
function ScopeSwitch(props: { title: string; note: string; scope: string }) {
  return <Toggle title={props.title} note={props.note} checked={scopeOn(props.scope)} disabled={!enabled()} onChange={v => void change({ op: "configure", aiAccessScopes: { ...cfg().aiAccessScopes, [props.scope]: v } })} />;
}
function FixedScope(props: { title: string; note: string; tone: "blue" | "orange" | "red"; pill: string; last?: boolean }) {
  return <Row gap={10} style={{ paddingVertical: 11, borderBottomWidth: props.last ? 0 : 1, borderBottomColor: c().line2 }}>
    <View style={{ flex: 1, minWidth: 0, gap: 2 }}><T size={13}>{props.title}</T><T size={11} color={c().muted}>{props.note}</T></View>
    <Pill tone={props.tone}>{props.pill}</Pill>
  </Row>;
}

function PairSheet(props: { close: () => void }) {
  const name = signal("Claude Code"), note = signal(""), copying = signal(false), done = signal(false), pairedFp = signal("");
  let alive = true;
  cleanup(() => { alive = false; });
  cleanup(onLock(props.close));
  const hasDuplicate = () => {
    const clean = name().trim();
    return !!clean && clients().some((entry) => entry.name === clean);
  };
  const copySetup = async () => {
    if (copying() || !enabled()) return;
    copying.set(true);
    try {
      const current = await control({ op: "status" });
      if (!alive || phase() !== "unlocked") return;
      if (!current.helper || !current.socket) throw new Error("AI 服务尚未就绪，请稍后重试");
      const pair = await control({ op: "pair", name: name() });
      if (!alive || phase() !== "unlocked") return;
      if (pair.clientId && note().trim()) {
        await saveClientNote(pair.clientId, note());
      }
      if (pair.clientId) {
        clientFilter.set("all");
        expandedClientId.set(pair.clientId);
      }
      pairedFp.set(pair.fingerprint ?? "");
      await copySecret(aiSetupInstructions(current.helper, current.socket, pair.token), "AI 配置");
      done.set(true);
      void refresh();
    } catch (e) { if (alive) toast(aiError(e)); }
    finally { if (alive) copying.set(false); }
  };
  return <View testID="ai-pair-sheet" style={{ gap: 12 }}>
    <SheetTitle title="配对 AI 客户端" text="复制一段已包含令牌的 MCP 配置，粘贴给本机 AI 客户端即可。配对后遵循「访问范围」，密码等敏感字段仍需逐次确认。" />
    <View style={{ gap: 6 }}><T size={11.5} color={c().muted}>客户端名称</T><TextBox testID="ai-pair-name-input" label="客户端名称" value={name()} onChange={v => name.set(v)} placeholder="例如 Claude Code / Codex" /></View>
    <If when={hasDuplicate() && !done()}>
      <Banner tone="warn" title="当前已有同名客户端" style={{ marginBottom: 0, paddingVertical: 8 }}>
        建议填写下方备注以便通过场景区分，或在列表中清理旧令牌。
      </Banner>
    </If>
    <View style={{ gap: 6 }}><T size={11.5} color={c().muted}>备注 / 使用场景（可选）</T><TextBox testID="ai-pair-note-input" label="备注 / 使用场景" value={note()} onChange={v => note.set(v)} placeholder="例如：主开发终端、日常写作" /></View>
    <If when={done()}><Banner tone="ok" title={pairedFp() ? `配置已复制（已分配指纹 #${pairedFp()}）` : "配置已复制"} style={{ marginBottom: 0 }}>直接粘贴给 AI；剪贴板 30 秒后自动清除。令牌明文仅显示一次，泄露时可在此页暂停或撤销该客户端。</Banner></If>
    <SheetFooter><Btn label={done() ? "完成" : "关闭"} kind={done() ? "primary" : "default"} onPress={props.close} /><If when={!done()}><Btn testID="ai-pair-copy-btn" label={copying() ? "正在准备…" : "复制给 AI"} icon="copy" kind="primary" disabled={!enabled() || copying() || !name().trim()} onPress={() => void copySetup()} /></If></SheetFooter>
  </View>;
}

function ExcludedEntriesSheet(props: { close: () => void }) {
  const query = signal("");
  cleanup(onLock(props.close));
  const current = () => excludedMap();
  const candidates = () => {
    const q = query().trim().toLowerCase();
    return items()
      .filter(item => !item.isDeleted && item.type !== "crypto" && item.type !== "totp" && (!q || `${item.title} ${item.username ?? ""} ${item.category ?? ""}`.toLowerCase().includes(q)))
      .sort((a, b) => Number(!!current()[b.id]) - Number(!!current()[a.id]) || String(a.title ?? "").localeCompare(String(b.title ?? ""), "zh-Hans-CN"))
      .slice(0, 80);
  };
  const toggleExclude = (item: Item) => {
    const next = { ...current() };
    if (next[item.id]) delete next[item.id];
    else next[item.id] = true;
    void change({ op: "configure", aiAccessExcludedEntries: next });
  };
  return <View testID="ai-excluded-entries-sheet" style={{ gap: 12 }}>
    <SheetTitle title="管理对 AI 隐藏的条目" text="极少数不希望被 AI 搜索或读取的私密条目可在此隐藏；其余条目自动按「访问范围」生效，密码仍需逐次确认。" />
    <TextBox label="搜索条目" placeholder="搜索标题、用户名或分类…" value={query()} onChange={v => query.set(v)} />
    <Scroll style={{ maxHeight: 360 }}>
      <If when={candidates().length > 0} else={<T size={12} color={c().faint}>没有匹配的条目</T>}>
        <Divided rows={candidates()} render={(item: Item) => {
          const hidden = () => !!current()[item.id];
          return <Row gap={10}>
            <IconTile name={ICON[item.type] ?? "key"} size={28} />
            <View style={{ flex: 1, minWidth: 0 }}>
              <T size={12.5} weight="500" lines={1}>{item.title || "未命名"}</T>
              <T size={11} color={c().muted}>{TYPE_NAME[item.type]}{item.category ? ` · ${item.category}` : ""}{hidden() ? " · 已对 AI 隐藏" : ""}</T>
            </View>
            <Btn label={hidden() ? "恢复可见" : "对 AI 隐藏"} kind={hidden() ? "default" : "ghost"} onPress={() => toggleExclude(item)} />
          </Row>;
        }} />
      </If>
    </Scroll>
    <SheetFooter><Btn label="完成" kind="primary" onPress={props.close} /></SheetFooter>
  </View>;
}

function WritableCategoriesSheet(props: { close: () => void }) {
  const custom = signal("");
  cleanup(onLock(props.close));
  const current = () => aiWritableCategories();
  const known = () => [...new Set([...noteCategories(), ...current()])].sort((a, b) => a.localeCompare(b, "zh-Hans-CN"));
  const addCustom = () => {
    const clean = custom().trim().replace(/^\/+|\/+$/g, "");
    if (!clean) return;
    custom.set("");
    void setCategoryAiWritable(clean, true);
  };
  return (
    <View testID="ai-writable-categories-sheet" style={{ gap: 12 }}>
      <SheetTitle
        title="管理 AI 可自动保存的笔记目录"
        text="白名单中的目录（含子目录）允许已配对 AI 免弹窗增量更新和归档附件；每次写入都必须带摘要并自动保留加密版本历史。"
      />
      <Row gap={8}>
        <View style={{ flex: 1 }}>
          <TextBox
            testID="ai-writable-custom-input"
            value={custom()}
            onChange={(v) => custom.set(v)}
            placeholder="输入目录前缀，如 资产/持仓 或 健康"
            onSubmit={addCustom}
          />
        </View>
        <Btn testID="ai-writable-custom-add" label="加入白名单" kind="primary" disabled={!custom().trim().replace(/^\/+|\/+$/g, "")} onPress={addCustom} />
      </Row>
      <Scroll style={{ maxHeight: 300 }}>
        <If when={known().length > 0} else={<T size={12} color={c().faint}>当前还没有笔记目录，可在上方直接添加目录前缀。</T>}>
          <Divided
            rows={known()}
            render={(cat: string) => {
              const on = () => current().includes(cat);
              return (
                <Row gap={10}>
                  <Icon name="folder" size={14} tint={on() ? c().blue : c().muted} />
                  <T size={12.5} weight={on() ? "600" : "400"} color={on() ? c().blue : c().ink} style={{ flex: 1 }}>
                    {cat}
                  </T>
                  <Btn
                    label={on() ? "移除" : "允许写入"}
                    kind={on() ? "ghost" : "default"}
                    onPress={() => void setCategoryAiWritable(cat, !on())}
                  />
                </Row>
              );
            }}
          />
        </If>
      </Scroll>
      <Banner tone="info" title="安全边界始终生效" style={{ marginBottom: 0 }}>
        AI 永远不能永久删除笔记、清理历史版本，也不能修改账号密码、银行卡、身份、设备或钱包条目。
      </Banner>
      <SheetFooter>
        <Btn label="完成" kind="primary" onPress={props.close} />
      </SheetFooter>
    </View>
  );
}

export function AiWorkspacePage() {
  const width = signal(900), allAudit = signal(false);
  void refresh();
  const body = () => {
    const rawAudit = (): any[] => (cfg().aiAccessAudit ?? []).filter((row: any) => row.operation !== "unlock");
    const leases = (): any[] => status().leases ?? [];
    const clientViews = () => buildAiClientViews(clients(), rawAudit(), leases(), clientNotesMap());
    const activeClient = () => clients().find(entry => entry.paused !== true) ?? clients()[0];
    const pick = (type: string) => items().find(item => item.type === type && !item.isDeleted && !excludedMap()[item.id]);
    const account = () => pick("password");
    const ready = () => enabled() && !!activeClient();
    const noteAutoWriteOn = () => aiSettings().aiAccessNoteAutoWrite === true;
    const writableCats = () => aiWritableCategories();
    const filteredAudit = () => {
      const target = auditClientId();
      const rows = target ? rawAudit().filter((row: any) => row.client === target) : rawAudit();
      return rows.slice(0, allAudit() ? 50 : 6);
    };
    const auditFilterClient = () => {
      const target = auditClientId();
      return target ? clientViews().find((v) => v.id === target) ?? null : null;
    };
    const scopeSummary = () => {
      const labels = [
        scopeOn("accounts") && "账号",
        scopeOn("profiles") && "身份与银行卡",
        scopeOn("devices") && "设备与服务",
        scopeOn("notes") && "笔记",
      ].filter(Boolean);
      const writeLabel = scopeOn("notes") && noteAutoWriteOn() ? `${writableCats().length} 个可写目录` : "笔记只读";
      const exLabel = excludedCount() ? ` · 隐藏 ${excludedCount()} 条` : "";
      return `${labels.length ? labels.join(" / ") : "未开启分类"} · ${writeLabel}${exLabel}`;
    };
    const pair = () => openSheet({ width: 520, render: close => <PairSheet close={close} /> });
    const manageClients = () => openClientsManagerSheet({ views: clientViews, enabled, onPair: pair });
    const manageWritable = () => openSheet({ width: 520, render: close => <WritableCategoriesSheet close={close} /> });
    const manageExcluded = () => openSheet({ width: 540, render: close => <ExcludedEntriesSheet close={close} /> });
    const endLeases = (body: Record<string, unknown> = {}) => void control({ op: "end_leases", ...body }).then(() => refresh(), e => toast(aiError(e)));
    const toggleAutoWrite = (v: boolean) => {
      void change({ op: "configure", aiAccessNoteAutoWrite: v });
      vaultSettings.update((s) => ({ ...s, aiAccessNoteAutoWrite: v }));
    };
    const hero = <View testID="ai-workspace-hero" style={{ gap: 12, padding: 18, borderRadius: 12, borderWidth: 1, borderColor: c().blueLine, backgroundColor: c().blueSoft }}>
      <View style={{ flexDirection: "row", gap: 15, alignItems: "flex-start" }}>
        <IconTile name="spark" size={42} solid />
        <View style={{ flex: 1, minWidth: 0, gap: 5 }}>
          <Row gap={6}><View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: enabled() ? c().green : c().faint }} /><T size={11.5} color={enabled() ? c().green : c().muted}>{enabled() ? "本机 AI 接口已启用 · 锁定后停止读取" : "本机 AI 接口未启用"}</T></Row>
          <T size={18} weight="600">按范围开放摘要，仅密码逐次确认</T>
          <T size={12} color={c().ink2}>开启右侧「访问范围」后，已配对 AI 可直接搜索并读取非密码普通字段，无需逐条维护白名单；密码、卡号、私钥与私密脚本仍须由你逐次审批（默认仅剪贴板）。白名单目录支持免弹窗更新与加密归档。</T>
        </View>
        <View style={{ width: 128, gap: 8, alignItems: "stretch" }}>
          <Btn label={enabled() ? "停用接口" : "启用接口"} kind={enabled() ? "default" : "primary"} onPress={() => void change({ op: "configure", aiAccessEnabled: !enabled() })} />
          <Btn testID="ai-pair-client-btn" label="配对客户端" icon="plus" kind={enabled() ? "primary" : "default"} disabled={!enabled()} onPress={pair} />
        </View>
      </View>
      <HeroClientStrip
        views={clientViews}
        writableCount={() => writableCats().length}
        excludedCount={excludedCount}
        onManage={manageClients}
      />
    </View>;
    const pairedClientsCard = <PairedClientsCard
      views={clientViews}
      scopeSummary={scopeSummary}
      compact={() => width() < 760}
      onManage={manageClients}
    />;
    const leaseCard = <If when={leases().length > 0}><Card title="免确认授权" note="只保存在内存中，锁定、暂停客户端或到期后自动结束。" right={<Btn label="全部结束" kind="ghost" onPress={() => endLeases()} />}>
      <Divided rows={leases()} render={(lease: any) => {
        const cv = clientViews().find((v) => v.id === lease.client);
        return <Row gap={10}>
          <IconTile name="clock" />
          <View style={{ flex: 1, minWidth: 0, gap: 2 }}><T size={12.5} weight="500" lines={1}>{titleOf(lease.entryId) || "条目"} · {aiFieldLabel(lease.field)}</T><T size={11} color={c().muted}>{`${clientName(lease.client)}${cv ? ` #${cv.fingerprint}` : ""} · ${lease.reveal ? "可返回明文" : "仅剪贴板"} · ${lease.secondsLeft == null ? "锁定前有效" : `剩余 ${Math.max(1, Math.ceil(lease.secondsLeft / 60))} 分钟`}`}</T></View>
          <Btn label="结束" onPress={() => endLeases({ entryId: lease.entryId, field: lease.field })} />
        </Row>;
      }} />
    </Card></If>;
    const noteWriteCard = <Card
      title="个人知识库 · AI 免弹窗自动保存与资产归档"
      note="适合长期存放持仓、健康数据、工作经历与事件记录。仅对下方白名单目录开放写入与 PDF/Word 归档，绝不修改任何账号/卡片/设备/钱包。"
      right={<Btn testID="ai-manage-writable-btn" label="管理可写目录…" disabled={!enabled() || !scopeOn("notes")} onPress={manageWritable} />}
    >
      <Toggle
        title="允许已配对 AI 免弹窗更新白名单笔记"
        note={scopeOn("notes") ? "AI 每次写入或归档附件都必须提供变更摘要（summary），并自动记录加密版本历史。" : "请先在右侧“访问范围”中开启「笔记」。"}
        checked={noteAutoWriteOn()}
        disabled={!enabled() || !scopeOn("notes")}
        onChange={toggleAutoWrite}
      />
      <View style={{ gap: 6 }}>
        <T size={11.5} color={c().muted}>可写目录白名单（包含子目录）</T>
        <If
          when={writableCats().length > 0}
          else={<T size={12} color={c().faint}>暂未配置可写目录。点击右上角「管理可写目录…」或在笔记侧栏右键目录开启。</T>}
        >
          <Row gap={6} wrap>
            {writableCats().map((cat) => (
              <View
                style={{
                  flexDirection: "row", alignItems: "center", gap: 6,
                  paddingHorizontal: 9, paddingVertical: 4, borderRadius: 6,
                  backgroundColor: c().blueSoft, borderWidth: 1, borderColor: c().blueLine,
                }}
              >
                <Icon name="folder" size={11} tint={c().blue} />
                <T size={12} color={c().blue}>{cat}</T>
                <View
                  role="button"
                  accessibilityLabel={`从 AI 可写目录移除 ${cat}`}
                  onPress={() => void setCategoryAiWritable(cat, false)}
                  style={{ cursor: "pointer", padding: 2 }}
                >
                  <Icon name="x" size={10} tint={c().blue} />
                </View>
              </View>
            ))}
          </Row>
        </If>
      </View>
    </Card>;
    const requests = <Card title="试发请求" note="以已配对活跃客户端的身份发出，走与真实 MCP 完全相同的策略与审批。">
      <View style={{ gap: 8 }}>
        <ListRow icon="key" title={account() ? `请求 ${account()!.title || "账号"} 密码` : "请求账号密码"} note={account() ? "密码始终弹窗确认 · 默认放到剪贴板 30 秒" : "还没有账号条目"} disabled={!ready() || !account()} busy={busy() === `${account()?.id}:password`} onPress={() => void requestSecret(account()!, "password", "登录当前网页")} />
        <ListRow icon="note" title="试查知识库笔记列表" note="列出可读笔记（含 Slug 与可写目录）" disabled={!ready() || !scopeOn("notes")} busy={busy() === "note_list"} onPress={() => void trial("note_list", { op: "note_list" }, out => {
          const notes = Array.isArray(out) ? out : Array.isArray(out?.notes) ? out.notes : [];
          const cats = Array.isArray(out?.writableCategories) ? out.writableCategories : [];
          return `试查返回 ${notes.length} 篇笔记 · 可写目录 ${cats.length} 个`;
        })} />
        <ListRow icon="search" title="试查范围条目摘要" note="按右侧已开启的访问范围直接搜索（不含密码）" disabled={!ready()} busy={busy() === "search"} onPress={() => void trial("search", { op: "search", query: "" }, out => `试查返回 ${Array.isArray(out) ? out.length : 0} 条范围摘要`)} />
        <ListRow icon="plus" title="试请你填写账号" note="AI 找不到账号时会弹出表单" disabled={!ready()} busy={busy() === "ask"} onPress={() => void trial("ask", { op: "ask_user", title: "示例网站", url: "https://example.com", purpose: "试发请求" }, out => out.id ? "已保存并返回给客户端" : "已完成")} />
        <ListRow icon="tools" title="测试执行请求" note="始终拒绝 · 脚本只作为资料" disabled={!ready()} busy={busy() === "execute"} onPress={() => void trial("execute", { op: "execute", id: account()?.id ?? "" }, () => "执行请求未被拒绝，请检查 AI 设置")} />
      </View>
      <If when={!ready()}><T size={11} color={c().muted}>{enabled() ? "配对客户端后即可试发请求。" : "启用本机接口并配对客户端后即可试发请求。"}</T></If>
    </Card>;
    const recent = <Card
      title="最近访问"
      note="点击记录中的客户端标签，可按单个客户端筛选日志；记录不包含查询文本或秘密。"
      right={
        <Row gap={4}>
          <If when={!!auditFilterClient()}>
            <Btn label="显示全部" kind="ghost" onPress={() => auditClientId.set(null)} />
          </If>
          <If when={rawAudit().length > 6}>
            <Btn label={allAudit() ? "收起" : "查看更多"} kind="ghost" onPress={() => allAudit.set(!allAudit())} />
          </If>
        </Row>
      }
    >
      <If when={!!auditFilterClient()}>
        <Row
          testID="ai-audit-filter-banner"
          gap={8}
          style={{
            paddingHorizontal: 10,
            paddingVertical: 6,
            borderRadius: 8,
            backgroundColor: c().blueSoft,
            borderWidth: 1,
            borderColor: c().blueLine,
          }}
        >
          <Icon name="filter" size={12} tint={c().blue} />
          <T size={11.5} color={c().blue} style={{ flex: 1 }} lines={1}>
            {`仅看：${auditFilterClient()!.name}${auditFilterClient()!.note ? `（${auditFilterClient()!.note}）` : ""} #${auditFilterClient()!.fingerprint}`}
          </T>
          <IconBtn icon="x" size={12} tint={c().blue} label="取消日志筛选" onPress={() => auditClientId.set(null)} />
        </Row>
      </If>
      <If
        when={filteredAudit().length > 0}
        else={<T size={12} color={c().faint}>{auditFilterClient() ? "该客户端暂无访问记录" : "暂无访问记录"}</T>}
      >
        <Divided rows={filteredAudit()} render={(row: any) => {
          const cv = clientViews().find((v) => v.id === row.client);
          const tail = [titleOf(row.item), relativeAuditTime(row.unixSeconds)].filter(Boolean).join(" · ");
          return <Row gap={10} style={{ alignItems: "flex-start" }}>
            <View style={{ width: 7, height: 7, borderRadius: 4, marginTop: 5, backgroundColor: row.result === "Allowed" || row.result === "AllowedByLease" ? c().green : c().orange }} />
            <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
              <T size={12} weight="500">{AI_OPS[row.operation] ?? row.operation} · {AI_RESULTS[row.result] ?? "已拒绝"}</T>
              <Row gap={4} wrap>
                <If
                  when={!!cv}
                  else={<T size={11} color={c().muted}>{clientName(row.client)}</T>}
                >
                  <View
                    role="button"
                    accessibilityLabel={`按 ${cv!.name} 筛选日志`}
                    onPress={() => auditClientId.set(auditClientId() === cv!.id ? null : cv!.id)}
                    style={{ paddingHorizontal: 4, paddingVertical: 1, borderRadius: 4, cursor: "pointer" }}
                    hoverStyle={{ backgroundColor: c().blueSoft }}
                  >
                    <T size={11} color={c().blue}>{`${cv!.name} #${cv!.fingerprint.slice(0, 4)}`}</T>
                  </View>
                </If>
                <If when={!!tail}><T size={11} color={c().muted} lines={1}>{`· ${tail}`}</T></If>
              </Row>
            </View>
          </Row>;
        }} />
      </If>
    </Card>;
    const scope = <View testID="ai-workspace-scopes"><Card
      title="访问范围"
      note={enabled() ? "开启的类别直接对已配对客户端生效，无需逐条添加；仅密码与密钥仍需逐次确认。" : "启用接口后可设置。"}
      right={<Btn testID="ai-manage-excluded-btn" label={excludedCount() ? `已隐藏 ${excludedCount()} 条` : "对 AI 隐藏…"} kind="ghost" disabled={!enabled()} onPress={manageExcluded} />}
    >
      <View>
        <ScopeSwitch title="账号摘要" note="标题、网站、用户名与备注（密码仍逐次确认）" scope="accounts" />
        <ScopeSwitch title="身份与银行卡" note="身份信息与卡片摘要可查；卡号与安全码逐次确认" scope="profiles" />
        <ScopeSwitch title="设备与服务" note="主机、端口、服务与普通命令；密码、私钥与私密脚本逐次确认" scope="devices" />
        <ScopeSwitch title="笔记" note="可读笔记与属性；白名单目录可免弹窗自动写入" scope="notes" />
        <Toggle
          title="资产归档与文档文本读取"
          note="允许 note_attach 归档 ≤ 100 MB 文件；note_read_asset 仅限已单独开启「AI 可读文本」的附件"
          checked={noteAssetsOn()}
          disabled={!enabled() || !scopeOn("notes")}
          onChange={v => void change({ op: "configure", aiAccessScopes: { ...cfg().aiAccessScopes, noteAssets: v } })}
        />
        <FixedScope title="密码、卡号、私钥与私密脚本" note="必须逐次弹窗确认；默认放到剪贴板 30 秒，AI 看不到明文" tone="orange" pill="按需确认" />
        <FixedScope title="删除笔记与修改凭据" note="AI 接口永远不允许永久删除笔记、清理历史或修改已有凭据" tone="red" pill="禁止操作" />
        <FixedScope title="钱包、助记词和私钥" note="AI 接口不开放" tone="red" pill="不可查询" last />
      </View>
    </Card></View>;
    const tools = <View testID="ai-workspace-tools"><Card title="AI 可用的 MCP 工具" note="按范围读取普通字段，仅密码等密钥需审批；资产按 64 KiB 分块加密存于 blobs/。">
      <View style={{ backgroundColor: c().soft2, borderRadius: 8, borderWidth: 1, borderColor: c().line, padding: 10, gap: 4 }}>
        {MCP_TOOLS.map((tool) => <Row gap={8}><T mono size={11.5} style={{ width: 108 }}>{tool.name}</T><T size={11} color={c().muted} style={{ flex: 1 }}>{tool.uiSummary}</T></Row>)}
      </View>
    </Card></View>;
    return <View onLayout={e => width.set(e.bounds.size.width)} style={{ gap: 14, maxWidth: 1080 }}>
      {hero}
      <If when={width() >= 760} else={<View style={{ gap: 14 }}>{pairedClientsCard}{leaseCard}{noteWriteCard}{requests}{scope}{recent}{tools}</View>}>
        <Row gap={14} style={{ alignItems: "flex-start" }}>
          <View style={{ flex: 1, minWidth: 0, gap: 14 }}>{pairedClientsCard}{leaseCard}{noteWriteCard}{requests}{recent}</View>
          <View style={{ width: 326, gap: 14 }}>{scope}{tools}</View>
        </Row>
      </If>
    </View>;
  };
  return <View style={{ flex: 1, backgroundColor: c().surface }}>
    <ToolHeader title="AI 访问" icon="spark" parent={null} />
    <Scroll style={{ flex: 1 }} contentStyle={{ paddingHorizontal: 44, paddingTop: 28, paddingBottom: 40 }}>
      <T size={23} weight="600">AI 访问</T>
      <T color={c().muted} style={{ marginTop: 4, marginBottom: 16 }}>让本机 AI 按范围查询非密码资料并自动维护个人知识库（MCP）。默认关闭，锁定后拒绝全部读取。</T>
      <If when={desktopCapabilities.ai} else={<Banner tone="info" title="此平台暂未开放 AI 访问" style={{ marginBottom: 0 }}>预览版暂不支持 AI 客户端访问密码库。</Banner>}>{body()}</If>
    </Scroll>
  </View>;
}
