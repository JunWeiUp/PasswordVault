import { cleanup, signal, Scroll, View } from "nsh";
import { Banner, Btn, openSheet, SheetTitle, SheetFooter, T, Toggle } from "../kit";
import { call, errorText, flush, items, load, now, onLock, phase, type Item } from "../store";
import { askEnableHistory, historyWarning } from "../recovery";

type Revision = { id: string; capturedAt: number; item: Item; deviceName?: string; deviceId?: string };
export function differingFields(a: Record<string, unknown>, b: Record<string, unknown>): string[] {
  return [...new Set([...Object.keys(a), ...Object.keys(b)])].filter(k => JSON.stringify(a[k]) !== JSON.stringify(b[k])).sort();
}
export function openItemHistory(item: Item) {
  if (phase() !== "unlocked") return;
  openSheet({ width: 680, render: close => <History item={item} close={close} /> });
}
function History(props: { item: Item; close: () => void }) {
  const revisions = signal<Revision[]>([]), total = signal(0), enabled = signal(false), selected = signal<Revision | null>(null);
  const reveal = signal(false), busy = signal(false), error = signal(""), confirm = signal<"restore" | "prune" | null>(null);
  let alive = true;
  const clear = () => { revisions.set([]); selected.set(null); reveal.set(false); };
  cleanup(() => { alive = false; clear(); });
  cleanup(onLock(() => { clear(); props.close(); }));
  const run = async (fn: () => Promise<void>) => { if (busy()) return; busy.set(true); error.set(""); try { await fn(); } catch (e) { if (alive) error.set(errorText(e)); } finally { if (alive) busy.set(false); } };
  const refresh = async (append = false) => {
    await flush();
    const status = await call({ op: "history-status" });
    const page = status.enabled ? await call({ op: "history-list", id: props.item.id, offset: append ? revisions().length : 0, limit: 30 }) : { revisions: [], total: 0 };
    if (!alive) return;
    enabled.set(status.enabled); total.set(page.total);
    revisions.set(append ? [...revisions(), ...page.revisions.filter((r: Revision) => !revisions().some(old => old.id === r.id))] : page.revisions);
  };
  void run(() => refresh());
  const current = () => items().find(i => i.id === props.item.id) ?? props.item;
  const act = () => run(async () => {
    const action = confirm(); const revisionId = selected()?.id;
    await flush(); if (!alive || phase() !== "unlocked") return;
    if (action === "restore" && revisionId) {
      await call({ op: "history-restore", id: props.item.id, revisionId, time: now() }); await load(); if (alive) props.close();
    } else if (action === "prune") {
      await call({ op: "history-prune", id: props.item.id }); clear(); await refresh();
    }
    if (alive) confirm.set(null);
  });
  return <View style={{ gap: 12 }}><SheetTitle title="条目版本历史" text={props.item.title} />
    <If when={error()}><Banner tone="err" title={error()} /></If>
    <If when={enabled()} else={<><Banner tone="warn" title="完整历史尚未启用">{historyWarning}</Banner><Btn label="启用完整历史…" disabled={busy()} onPress={() => askEnableHistory(() => openItemHistory(props.item))} /></>}>
      <T>恢复会创建一个新版本。永久删除条目也会删除本机历史，已有备份不受影响。</T>
      <Scroll style={{ maxHeight: 190 }}><View style={{ gap: 6 }}>{revisions().map(r => <View>
        <Btn label={`${new Date(r.capturedAt).toLocaleString()} · ${r.deviceName ?? r.deviceId ?? "设备未记录"}`} disabled={busy()} onPress={() => { selected.set(r); reveal.set(false); confirm.set(null); }} />
        <T size={11}>与当前版本不同的字段：{differingFields(r.item ?? {}, current()).join("、") || "无"}</T>
      </View>)}</View></Scroll>
      <T>{revisions().length} / {total()} 个版本</T>
      <If when={revisions().length < total()}><Btn label="加载更多版本" disabled={busy()} onPress={() => run(() => refresh(true))} /></If>
      <If when={selected()}><T>与当前版本不同的字段：{differingFields(selected()?.item ?? {}, current()).join("、") || "无"}</T>
        <Toggle title="显示完整内容（包含敏感信息）" checked={reveal()} onChange={v => reveal.set(v)} />
        <If when={reveal()}><Scroll style={{ maxHeight: 220 }}><T mono selectable>{JSON.stringify(selected()?.item, null, 2)}</T></Scroll></If>
        <Btn label="恢复此版本…" disabled={busy() || !selected()?.item || !!props.item.isDeleted} onPress={() => confirm.set("restore")} />
      </If>
      <Btn label="清理旧版本…" kind="danger" disabled={busy() || !!props.item.isDeleted} onPress={() => confirm.set("prune")} />
      <If when={confirm()}><Banner tone="warn" title={confirm() === "restore" ? "恢复所选版本？" : "清理此条目的旧版本？"}>
        {confirm() === "restore" ? "当前内容保留在历史中，恢复内容成为新版本。" : "保留当前内容。个人库删除本机旧版本；对等库仅隐藏，内容仍在同步日志中。已有备份不受影响。"}
      </Banner><Btn label="取消操作" disabled={busy()} onPress={() => confirm.set(null)} /><Btn label={confirm() === "restore" ? "确认恢复版本" : "确认清理旧版本"} disabled={busy()} onPress={act} /></If>
    </If><SheetFooter><Btn label="关闭" disabled={busy()} onPress={props.close} /></SheetFooter></View>;
}
