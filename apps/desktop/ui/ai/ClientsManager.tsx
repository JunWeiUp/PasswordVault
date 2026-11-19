// Interactive Paired AI Clients strip, inline expandable management card,
// edit name/note sheet, unused cleanup confirmation, and batch manager sheet.
// Business logic & telemetry aggregation live in `../api/aiClients.ts`;
// client remarks live in encrypted `settings.uiPrefs.aiClientNotes` (no Rust schema changes).
import { cleanup, Scroll, signal, View } from "nsh";
import { Menu, type MenuItem } from "nsh/desktop";
import { Icon } from "../icons";
import { Banner, Btn, Card, IconBtn, Pill, Row, SheetFooter, SheetTitle, Spacer, T, TextBox, confirm, openSheet } from "../kit";
import { onLock, toast } from "../store";
import { c, fs, radius } from "../theme";
import { getUiPref, setUiPref } from "../api/extensions";
import {
  AI_CLIENT_NOTES_PREF_KEY,
  clientStateLabel,
  clientSubline,
  countAiClientStates,
  filterAiClients,
  findDuplicateClientNames,
  formatPairedTime,
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

async function pruneNotesAfterRevoke(revokedIds: string[]): Promise<void> {
  const removed = new Set(revokedIds);
  const current = clientNotesMap();
  const kept = Object.keys(current).filter((id) => !removed.has(id));
  if (kept.length !== Object.keys(current).length) {
    await setUiPref(AI_CLIENT_NOTES_PREF_KEY, pruneClientNotes(current, kept));
  }
}

function stateTone(state: AiClientState): "green" | "blue" | "orange" | "gray" {
  return ({ active: "green", idle: "blue", paused: "orange", unused: "gray" } as const)[state];
}

function StatusDot(props: { state: AiClientState; size?: number }) {
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

function FingerprintChip(props: { fp: string; prefix?: string }) {
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

function Checkbox(props: { checked: boolean; label: string; onToggle: () => void }) {
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

function SoftActionBtn(props: { label: string; icon?: "pause" | "play" | "edit" | "history" | "trash"; tone?: "default" | "blue" | "orange" | "danger"; onPress: () => void; testID?: string; tooltip?: string }) {
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

export function openEditClientSheet(client: AiClientView, onDone?: () => void): void {
  openSheet({
    width: 480,
    render: (close) => <EditClientSheet client={client} close={close} onDone={onDone} />,
  });
}

function EditClientSheet(props: { client: AiClientView; close: () => void; onDone?: () => void }) {
  const name = signal(props.client.name);
  const note = signal(props.client.note);
  const saving = signal(false);
  cleanup(onLock(props.close));

  const save = async () => {
    const cleanName = name().trim();
    if (!cleanName || saving()) return;
    saving.set(true);
    try {
      if (cleanName !== props.client.name) {
        await change({ op: "rename", clientId: props.client.id, name: cleanName });
      }
      if (note().trim() !== props.client.note) {
        await saveClientNote(props.client.id, note());
      }
      toast("已更新客户端信息");
      props.close();
      props.onDone?.();
    } finally {
      saving.set(false);
    }
  };

  return (
    <View testID="ai-edit-client-sheet" style={{ gap: 12 }}>
      <SheetTitle
        title="编辑已配对客户端"
        text="为客户端设置清晰的名称与使用场景备注，便于在多个同名客户端中快速辨认。"
      />
      <Row
        gap={8}
        wrap
        style={{
          paddingHorizontal: 10,
          paddingVertical: 8,
          borderRadius: 8,
          backgroundColor: c().soft2,
          borderWidth: 1,
          borderColor: c().line,
        }}
      >
        <T size={11.5} color={c().muted}>令牌短指纹</T>
        <T mono size={11.5} weight="600" color={c().blue}>{`#${props.client.fingerprint}`}</T>
        <T size={11} color={c().muted}>{`· 配于 ${formatPairedTime(props.client.createdUnix)} · 累计调用 ${props.client.callsTotal} 次`}</T>
      </Row>
      <View style={{ gap: 5 }}>
        <T size={11.5} color={c().muted}>客户端名称</T>
        <TextBox testID="ai-edit-client-name" label="客户端名称" value={name()} onChange={(v) => name.set(v)} placeholder="例如 Claude Code / Codex" onSubmit={() => void save()} />
      </View>
      <View style={{ gap: 5 }}>
        <T size={11.5} color={c().muted}>备注 / 使用场景（可选，仅加密保存于本库）</T>
        <TextBox testID="ai-edit-client-note" label="备注 / 使用场景" value={note()} onChange={(v) => note.set(v)} placeholder="例如：主开发终端、旧工作区、日常写作" autoFocus onSubmit={() => void save()} />
      </View>
      <SheetFooter>
        <Btn label="取消" onPress={() => { props.close(); props.onDone?.(); }} />
        <Btn testID="ai-edit-client-save" label={saving() ? "保存中…" : "保存"} kind="primary" disabled={!name().trim() || saving()} onPress={() => void save()} />
      </SheetFooter>
    </View>
  );
}

export function openCleanupUnusedSheet(unused: AiClientView[], onDone?: () => void): void {
  if (!unused.length) {
    toast("当前没有未使用的客户端");
    return;
  }
  openSheet({
    width: 500,
    render: (close) => <CleanupUnusedSheet targets={unused} close={close} onDone={onDone} />,
  });
}

function CleanupUnusedSheet(props: { targets: AiClientView[]; close: () => void; onDone?: () => void }) {
  const busy = signal(false);
  cleanup(onLock(props.close));

  const doRevoke = async () => {
    if (busy()) return;
    busy.set(true);
    try {
      const ids = props.targets.map((t) => t.id);
      await change({ op: "revoke_many", clientIds: ids });
      await pruneNotesAfterRevoke(ids);
      const idSet = new Set(ids);
      if (expandedClientId() && idSet.has(expandedClientId()!)) expandedClientId.set(null);
      if (auditClientId() && idSet.has(auditClientId()!)) auditClientId.set(null);
      toast(`已清理 ${ids.length} 个未使用的客户端`);
      props.close();
      props.onDone?.();
    } finally {
      busy.set(false);
    }
  };

  return (
    <View testID="ai-cleanup-unused-sheet" style={{ gap: 12 }}>
      <SheetTitle
        title={`清理 ${props.targets.length} 个未使用的客户端？`}
        text="以下客户端配对后从未发起过任何请求。撤销后对应令牌立即失效，可随时重新配对。"
      />
      <Scroll style={{ maxHeight: 260 }}>
        <View style={{ borderWidth: 1, borderColor: c().line, borderRadius: 9, overflow: "hidden" }}>
          {props.targets.map((item, idx) => (
            <Row
              gap={10}
              style={{
                paddingHorizontal: 12,
                paddingVertical: 9,
                borderBottomWidth: idx === props.targets.length - 1 ? 0 : 1,
                borderBottomColor: c().line2,
              }}
            >
              <StatusDot state="unused" />
              <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
                <Row gap={6} wrap>
                  <T size={12.5} weight="600">{item.name}</T>
                  <If when={!!item.note}><Pill tone="blue">{item.note}</Pill></If>
                  <FingerprintChip fp={item.fingerprint} />
                </Row>
                <T size={11} color={c().muted}>{`配于 ${formatPairedTime(item.createdUnix)} · 从未调用`}</T>
              </View>
            </Row>
          ))}
        </View>
      </Scroll>
      <SheetFooter>
        <Btn label="取消" onPress={() => { props.close(); props.onDone?.(); }} />
        <Btn testID="ai-cleanup-unused-confirm" label={busy() ? "正在撤销…" : `撤销这 ${props.targets.length} 个客户端`} kind="dangerSolid" disabled={busy()} onPress={() => void doRevoke()} />
      </SheetFooter>
    </View>
  );
}

export function openClientsManagerSheet(opts: {
  views: () => AiClientView[];
  enabled: () => boolean;
  onPair: () => void;
}): void {
  openSheet({
    width: 780,
    render: (close) => <ClientsManagerSheet views={opts.views} enabled={opts.enabled} onPair={opts.onPair} close={close} />,
  });
}

function ClientsManagerSheet(props: {
  views: () => AiClientView[];
  enabled: () => boolean;
  onPair: () => void;
  close: () => void;
}) {
  const filter = signal<AiClientFilter>("all");
  const search = signal("");
  const selected = signal<string[]>([]);
  const revoking = signal(false);
  cleanup(onLock(props.close));

  const reopen = () => openClientsManagerSheet({ views: props.views, enabled: props.enabled, onPair: props.onPair });
  const counts = () => countAiClientStates(props.views());
  const dups = () => findDuplicateClientNames(props.views());
  const filtered = () => filterAiClients(props.views(), filter(), search());
  const liveSelected = () => {
    const live = new Set(props.views().map((v) => v.id));
    return selected().filter((id) => live.has(id));
  };
  const allFilteredChecked = () => filtered().length > 0 && filtered().every((v) => liveSelected().includes(v.id));

  const toggleOne = (id: string) => {
    selected.update((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  };
  const toggleAllFiltered = () => {
    const ids = filtered().map((v) => v.id);
    if (allFilteredChecked()) {
      const rm = new Set(ids);
      selected.update((prev) => prev.filter((x) => !rm.has(x)));
    } else {
      selected.update((prev) => [...new Set([...prev, ...ids])]);
    }
  };
  const selectUnused = () => {
    const unusedIds = props.views().filter((v) => v.filterKey === "unused").map((v) => v.id);
    selected.set(unusedIds);
    toast(`已勾选 ${unusedIds.length} 个未使用的客户端`);
  };
  const revokeSelected = () => {
    const ids = liveSelected();
    if (!ids.length) return;
    const targets = props.views().filter((v) => ids.includes(v.id));
    confirm({
      title: `撤销已选的 ${targets.length} 个客户端？`,
      text: "这些客户端的令牌将立即失效，关联的免确认授权也会同时结束。",
      ok: `确认撤销 (${targets.length})`,
      danger: true,
      onCancel: reopen,
      onConfirm: () => {
        void (async () => {
          revoking.set(true);
          try {
            await change({ op: "revoke_many", clientIds: ids });
            await pruneNotesAfterRevoke(ids);
            const idSet = new Set(ids);
            if (expandedClientId() && idSet.has(expandedClientId()!)) expandedClientId.set(null);
            if (auditClientId() && idSet.has(auditClientId()!)) auditClientId.set(null);
            toast(`已批量撤销 ${ids.length} 个客户端`);
            reopen();
          } finally {
            revoking.set(false);
          }
        })();
      },
    });
  };

  return (
    <View testID="ai-clients-manager-sheet" style={{ gap: 11 }}>
      <Row gap={10} style={{ alignItems: "flex-start" }}>
        <View style={{ flex: 1, minWidth: 0, gap: 4 }}>
          <Row gap={8}>
            <T size={17} weight="600">管理已配对客户端</T>
            <Pill tone="blue">{String(counts().total)}</Pill>
          </Row>
          <T size={12} color={c().muted}>通过备注与令牌短指纹区分同名客户端；支持暂时暂停访问、筛选日志或批量清理闲置令牌。</T>
        </View>
        <Btn label="配对新客户端" icon="plus" kind="primary" disabled={!props.enabled()} onPress={() => { props.close(); props.onPair(); }} />
      </Row>

      <If when={dups().length > 0 || counts().unused > 0}>
        <Banner
          tone="warn"
          title={
            [
              dups().length ? `检测到同名客户端（${dups().map(([n, k]) => `${n} ×${k}`).join("、")}）` : "",
              counts().unused ? `${counts().unused} 个从未调用` : "",
            ].filter(Boolean).join(" · ")
          }
          style={{ marginBottom: 0, paddingVertical: 8 }}
          actions={
            counts().unused > 0 ? (
              <Btn
                label={`清理未使用 (${counts().unused})`}
                onPress={() => openCleanupUnusedSheet(props.views().filter((v) => v.filterKey === "unused"), reopen)}
              />
            ) : undefined
          }
        >
          建议补充备注区分，或一键清理从未调用的闲置令牌。
        </Banner>
      </If>

      <Row gap={10} wrap style={{ justifyContent: "space-between" }}>
        <Row gap={4} wrap style={{ padding: 2, borderRadius: 8, backgroundColor: c().field }}>
          {(
            [
              ["all", "全部", counts().total],
              ["active", "活跃", counts().active],
              ["paused", "已暂停", counts().paused],
              ["unused", "未使用", counts().unused],
            ] as const
          ).map(([key, label, count]) => {
            const on = () => filter() === key;
            return (
              <View
                role="tab"
                accessibilityState={{ selected: on() }}
                onPress={() => filter.set(key)}
                style={{
                  flexDirection: "row",
                  alignItems: "center",
                  gap: 4,
                  paddingHorizontal: 9,
                  height: fs(25),
                  borderRadius: 6,
                  backgroundColor: on() ? c().surface : "transparent",
                  cursor: "pointer",
                }}
              >
                <T size={11.5} weight={on() ? "600" : "400"} color={on() ? c().blue : c().muted}>{label}</T>
                <T size={10.5} color={on() ? c().blue : c().faint}>{String(count)}</T>
              </View>
            );
          })}
        </Row>
        <View style={{ width: 220 }}>
          <TextBox label="搜索客户端" placeholder="搜索名称、备注或指纹…" value={search()} onChange={(v) => search.set(v)} />
        </View>
      </Row>

      <Scroll style={{ maxHeight: 360 }}>
        <If
          when={filtered().length > 0}
          else={
            <View style={{ paddingVertical: 30, alignItems: "center", gap: 4, borderWidth: 1, borderColor: c().line, borderRadius: 9, backgroundColor: c().soft2 }}>
              <T size={12.5} weight="600">没有匹配的客户端</T>
              <T size={11.5} color={c().muted}>可以调整筛选条件，或点击右上角配对新客户端。</T>
            </View>
          }
        >
          <View style={{ borderWidth: 1, borderColor: c().line, borderRadius: 9, overflow: "hidden" }}>
            <Row
              gap={10}
              style={{
                paddingHorizontal: 10,
                paddingVertical: 7,
                backgroundColor: c().soft2,
                borderBottomWidth: 1,
                borderBottomColor: c().line,
              }}
            >
              <Checkbox checked={allFilteredChecked()} label="全选当前列表" onToggle={toggleAllFiltered} />
              <T size={11} color={c().muted} style={{ flex: 1 }}>客户端与备注</T>
              <T size={11} color={c().muted} style={{ width: 76 }}>状态</T>
              <T size={11} color={c().muted} style={{ width: 175 }}>配对与活跃度</T>
              <T size={11} color={c().muted} align="right" style={{ width: 148 }}>管理操作</T>
            </Row>
            <Each of={filtered()} key={(item) => item.id}>
              {(item) => {
                const checked = () => liveSelected().includes(item().id);
                return (
                  <Row
                    gap={10}
                    style={{
                      paddingHorizontal: 10,
                      paddingVertical: 9,
                      borderBottomWidth: 1,
                      borderBottomColor: c().line2,
                      backgroundColor: checked() ? c().blueSoft : c().surface,
                    }}
                  >
                    <Checkbox checked={checked()} label={`选择 ${item().name}`} onToggle={() => toggleOne(item().id)} />
                    <View style={{ flex: 1, minWidth: 0, gap: 3 }}>
                      <Row gap={6} wrap>
                        <T size={12.5} weight="600" color={item().paused ? c().muted : c().ink} lines={1}>{item().name}</T>
                        <If
                          when={!!item().note}
                          else={
                            <View
                              role="button"
                              accessibilityLabel={`为 ${item().name} 添加备注`}
                              onPress={() => openEditClientSheet(item(), reopen)}
                              style={{ paddingHorizontal: 5, paddingVertical: 1, borderRadius: 4, borderWidth: 1, borderColor: c().line, cursor: "pointer" }}
                              hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blueLine }}
                            >
                              <T size={10.5} color={c().faint}>+ 备注</T>
                            </View>
                          }
                        >
                          <Pill tone="blue">{item().note}</Pill>
                        </If>
                      </Row>
                      <Row gap={6} wrap>
                        <FingerprintChip fp={item().fingerprint} />
                        <T size={10.5} color={c().muted} lines={1}>{item().lastOpLabel}</T>
                      </Row>
                    </View>
                    <View style={{ width: 76, alignItems: "flex-start" }}>
                      <Pill tone={stateTone(item().state)}>{clientStateLabel(item().state)}</Pill>
                    </View>
                    <View style={{ width: 175, gap: 2 }}>
                      <T size={11.5} lines={1}>{`配于 ${formatPairedTime(item().createdUnix)}`}</T>
                      <T size={10.5} color={c().muted} lines={1}>
                        {item().callsTotal > 0 ? `24h ${item().calls24h} 次 / 共 ${item().callsTotal} 次` : "从未调用 · 可清理"}
                      </T>
                    </View>
                    <Row gap={3} style={{ width: 148, justifyContent: "flex-end" }}>
                      <SoftActionBtn
                        label={item().paused ? "恢复" : "暂停"}
                        tone={item().paused ? "blue" : "default"}
                        onPress={() => void togglePauseClient(item())}
                      />
                      <IconBtn icon="edit" size={14} label="编辑名称与备注" onPress={() => openEditClientSheet(item(), reopen)} />
                      <IconBtn
                        icon="history"
                        size={14}
                        label="只看此客户端日志"
                        tint={auditClientId() === item().id ? c().blue : c().muted}
                        onPress={() => { toggleAuditFilter(item()); props.close(); }}
                      />
                      <IconBtn icon="trash" size={14} label="撤销此客户端" tint={c().red} onPress={() => revokeClientWithConfirm(item(), reopen)} />
                    </Row>
                  </Row>
                );
              }}
            </Each>
          </View>
        </If>
      </Scroll>

      <SheetFooter
        left={
          <Row gap={8} wrap>
            <T size={12} color={c().muted}>{`已选 ${liveSelected().length} 个`}</T>
            <If when={counts().unused > 0}>
              <Btn label={`勾选全部未使用 (${counts().unused})`} kind="ghost" onPress={selectUnused} />
            </If>
            <Btn label={`撤销已选 (${liveSelected().length})`} kind="danger" disabled={liveSelected().length === 0 || revoking()} onPress={revokeSelected} />
          </Row>
        }
      >
        <Btn label="完成" kind="primary" onPress={props.close} />
      </SheetFooter>
    </View>
  );
}

/** Full-width interactive status strip inside the AI Workspace hero card. */
export function HeroClientStrip(props: {
  views: () => AiClientView[];
  writableCount: () => number;
  excludedCount: () => number;
  onManage: () => void;
}) {
  const counts = () => countAiClientStates(props.views());
  const toggleChip = (f: "active" | "paused" | "unused") => {
    clientFilter.set(clientFilter() === f ? "all" : f);
  };
  const chip = (key: "active" | "paused" | "unused", label: string, state: AiClientState) => {
    const on = () => clientFilter() === key;
    return (
      <View
        role="button"
        testID={`ai-hero-chip-${key}`}
        accessibilityLabel={`筛选${label}`}
        onPress={() => toggleChip(key)}
        style={{
          flexDirection: "row",
          alignItems: "center",
          gap: 5,
          paddingHorizontal: 8,
          paddingVertical: 3,
          borderRadius: 99,
          borderWidth: 1,
          borderColor: on() ? c().blue : c().line,
          backgroundColor: on() ? c().blueSoft : c().surface,
          cursor: "pointer",
        }}
        hoverStyle={{ borderColor: c().blueLine, backgroundColor: c().blueSoft }}
      >
        <StatusDot state={state} size={6} />
        <T size={11} weight={on() ? "600" : "400"} color={on() ? c().blue : c().ink2}>{label}</T>
      </View>
    );
  };

  return (
    <Row
      testID="ai-hero-client-strip"
      gap={10}
      wrap
      style={{
        justifyContent: "space-between",
        paddingHorizontal: 12,
        paddingVertical: 9,
        borderRadius: 9,
        borderWidth: 1,
        borderColor: c().line,
        backgroundColor: c().surface,
      }}
    >
      <Row gap={8} wrap style={{ flex: 1, minWidth: 260 }}>
        <View style={{ width: 26, height: 26, borderRadius: 7, backgroundColor: c().blueSoft, alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
          <Icon name="shield" size={14} tint={c().blue} />
        </View>
        <T size={12.5} weight="600">
          {counts().total ? `${counts().total} 个已配对客户端` : "暂无已配对客户端"}
        </T>
        <If when={counts().total > 0} else={<T size={11} color={c().muted}>配对后即可按右侧访问范围直接使用</T>}>
          <Row gap={5} wrap>
            {chip("active", `${counts().active} 活跃`, "active")}
            <If when={counts().paused > 0}>{chip("paused", `${counts().paused} 已暂停`, "paused")}</If>
            <If when={counts().unused > 0}>{chip("unused", `${counts().unused} 未使用`, "unused")}</If>
          </Row>
        </If>
        <T size={11} color={c().muted}>
          {`· ${props.writableCount()} 个 AI 可写目录${props.excludedCount() ? ` · ${props.excludedCount()} 个已隐藏条目` : ""}`}
        </T>
      </Row>
      <Btn testID="ai-open-manager-btn" label="管理客户端…" onPress={props.onManage} />
    </Row>
  );
}

/** Prominent inline expandable paired clients card with filtering, search & cleanup. */
export function PairedClientsCard(props: {
  views: () => AiClientView[];
  scopeSummary: () => string;
  compact: () => boolean;
  onManage: () => void;
}) {
  const counts = () => countAiClientStates(props.views());
  const dups = () => findDuplicateClientNames(props.views());
  const filtered = () => filterAiClients(props.views(), clientFilter(), clientSearch());

  const rowMenu = (v: AiClientView): MenuItem[] => [
    { label: expandedClientId() === v.id ? "收起详情" : "展开详情", onSelect: () => expandedClientId.set(expandedClientId() === v.id ? null : v.id) },
    { label: "编辑名称与备注…", onSelect: () => openEditClientSheet(v) },
    { label: auditClientId() === v.id ? "取消日志筛选" : "只看此客户端日志", onSelect: () => toggleAuditFilter(v) },
    { label: v.paused ? "恢复访问权限" : "暂停访问（保留令牌）", onSelect: () => void togglePauseClient(v) },
    { type: "separator" },
    { label: "撤销此客户端…", onSelect: () => revokeClientWithConfirm(v) },
  ];

  return (
    <View testID="ai-paired-clients-card">
      <Card
        title="已配对客户端"
        note="按右侧「访问范围」生效，仅密码等秘密走 get_secret 审批。点击任意行展开指纹、活跃度与管理项。"
        right={
          <Row gap={6}>
            <Pill tone="blue">{String(counts().total)}</Pill>
            <If when={dups().length > 0}>
              <Pill tone="orange">{`${dups().length} 组同名`}</Pill>
            </If>
            <Btn testID="ai-batch-manage-btn" label="批量管理…" kind="ghost" onPress={props.onManage} />
          </Row>
        }
      >
        <If when={dups().length > 0 || counts().unused > 0}>
          <Row
            gap={8}
            wrap
            style={{
              paddingHorizontal: 10,
              paddingVertical: 8,
              borderRadius: 8,
              backgroundColor: c().orangeSoft,
              borderWidth: 1,
              borderColor: c().orange,
            }}
          >
            <Icon name="alert" size={14} tint={c().orange} />
            <T size={11.5} color={c().orange} style={{ flex: 1, minWidth: 180 }}>
              {`${dups().length ? `检测到同名客户端（${dups().map(([n, k]) => `${n} ×${k}`).join("、")}）` : ""}${dups().length && counts().unused ? "，且有 " : ""}${counts().unused ? `${counts().unused} 个从未调用` : ""}；建议添加备注区分或清理闲置令牌。`}
            </T>
            <If when={counts().unused > 0}>
              <Btn
                testID="ai-cleanup-unused-btn"
                label={`一键清理未使用 (${counts().unused})`}
                onPress={() => openCleanupUnusedSheet(props.views().filter((v) => v.filterKey === "unused"))}
              />
            </If>
          </Row>
        </If>

        <If when={counts().total > 0}>
          <Row gap={8} wrap style={{ justifyContent: "space-between" }}>
            <Row gap={2} wrap style={{ padding: 2, borderRadius: 8, backgroundColor: c().field }}>
              {(
                [
                  ["all", "全部", counts().total],
                  ["active", "活跃", counts().active],
                  ["paused", "已暂停", counts().paused],
                  ["unused", "未使用", counts().unused],
                ] as const
              ).map(([key, label, count]) => {
                const on = () => clientFilter() === key;
                return (
                  <View
                    role="tab"
                    testID={`ai-filter-${key}`}
                    accessibilityLabel={`${label} ${count}`}
                    accessibilityState={{ selected: on() }}
                    onPress={() => clientFilter.set(key)}
                    style={{
                      flexDirection: "row",
                      alignItems: "center",
                      gap: 4,
                      paddingHorizontal: 9,
                      height: fs(25),
                      borderRadius: 6,
                      backgroundColor: on() ? c().surface : "transparent",
                      cursor: "pointer",
                    }}
                  >
                    <T size={11.5} weight={on() ? "600" : "400"} color={on() ? c().blue : c().muted}>{label}</T>
                    <T size={10.5} color={on() ? c().blue : c().faint}>{String(count)}</T>
                  </View>
                );
              })}
            </Row>
            <View style={{ width: props.compact() ? "100%" : 210 }}>
              <TextBox
                testID="ai-client-search"
                label="搜索已配对客户端"
                placeholder="搜索名称、备注或指纹…"
                value={clientSearch()}
                onChange={(v) => clientSearch.set(v)}
              />
            </View>
          </Row>
        </If>

        <If
          when={counts().total > 0}
          else={
            <View style={{ paddingVertical: 22, paddingHorizontal: 14, alignItems: "center", gap: 4, borderRadius: 9, borderWidth: 1, borderColor: c().line, backgroundColor: c().soft2 }}>
              <T size={12.5} weight="600">暂无已配对客户端</T>
              <T size={11.5} color={c().muted}>点击上方「配对客户端」一键生成含令牌的 MCP 配置。</T>
            </View>
          }
        >
          <If
            when={filtered().length > 0}
            else={
              <View style={{ paddingVertical: 20, paddingHorizontal: 14, alignItems: "center", gap: 6, borderRadius: 9, borderWidth: 1, borderColor: c().line, backgroundColor: c().soft2 }}>
                <T size={12.5} weight="600">当前筛选下没有匹配的客户端</T>
                <T size={11} color={c().muted}>可切换状态筛选或清空搜索关键词。</T>
                <Btn label="重置筛选" kind="ghost" onPress={() => { clientFilter.set("all"); clientSearch.set(""); }} />
              </View>
            }
          >
            <View style={{ borderWidth: 1, borderColor: c().line, borderRadius: radius.card, overflow: "hidden", backgroundColor: c().surface }}>
              <Each of={filtered()} key={(item) => item.id}>
                {(item) => {
                  const open = () => expandedClientId() === item().id;
                  const auditOn = () => auditClientId() === item().id;
                  return (
                    <View
                      testID={`ai-client-row-${item().id}`}
                      style={{
                        borderBottomWidth: 1,
                        borderBottomColor: c().line2,
                        backgroundColor: open() ? c().blueSoft : c().surface,
                      }}
                    >
                      <Row
                        gap={8}
                        style={{
                          paddingHorizontal: 11,
                          paddingVertical: 10,
                          alignItems: "center",
                          cursor: "pointer",
                        }}
                      >
                        <View
                          role="button"
                          accessibilityLabel={`展开或收起 ${item().name}`}
                          onPress={() => expandedClientId.set(open() ? null : item().id)}
                          style={{ flex: 1, minWidth: 0, flexDirection: "row", alignItems: "center", gap: 8, cursor: "pointer" }}
                        >
                          <Icon name={open() ? "chevd" : "chev"} size={12} tint={c().faint} />
                          <StatusDot state={item().state} />
                          <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
                            <Row gap={6} wrap>
                              <T size={12.5} weight="600" color={item().paused ? c().muted : c().ink}>{item().name}</T>
                              <If
                                when={!!item().note}
                                else={
                                  <View
                                    role="button"
                                    accessibilityLabel={`为 ${item().name} 添加备注`}
                                    onPress={(e: any) => { e?.stopPropagation?.(); openEditClientSheet(item()); }}
                                    style={{ paddingHorizontal: 5, paddingVertical: 1, borderRadius: 4, borderWidth: 1, borderColor: c().line, cursor: "pointer" }}
                                    hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blueLine }}
                                  >
                                    <T size={10.5} color={c().faint}>+ 备注</T>
                                  </View>
                                }
                              >
                                <Pill tone="blue">{item().note}</Pill>
                              </If>
                              <FingerprintChip fp={item().fingerprint} />
                              <Pill tone={stateTone(item().state)}>{clientStateLabel(item().state)}</Pill>
                              <If when={item().hasLease}>
                                <Pill tone="blue">免确认中</Pill>
                              </If>
                            </Row>
                            <T size={11} color={c().muted} lines={1}>{clientSubline(item())}</T>
                          </View>
                        </View>

                        <If
                          when={open()}
                          else={
                            <Row gap={3}>
                              <SoftActionBtn
                                label={item().paused ? "恢复" : "暂停"}
                                icon={item().paused ? "play" : "pause"}
                                tone={item().paused ? "blue" : "default"}
                                onPress={() => void togglePauseClient(item())}
                              />
                              <IconBtn icon="edit" size={14} label="编辑名称与备注" onPress={() => openEditClientSheet(item())} />
                              <IconBtn
                                icon="history"
                                size={14}
                                label={auditOn() ? "取消日志筛选" : "只看此客户端日志"}
                                tint={auditOn() ? c().blue : c().muted}
                                onPress={() => toggleAuditFilter(item())}
                              />
                              <IconBtn
                                icon="more"
                                size={14}
                                label="更多操作"
                                onPress={(e: any) => void Menu.popup(rowMenu(item()), e?.pagePosition)}
                              />
                            </Row>
                          }
                        >
                          <Btn label="收起" kind="ghost" onPress={() => expandedClientId.set(null)} />
                        </If>
                      </Row>

                      <If when={open()}>
                        <View
                          testID="ai-client-inline-drawer"
                          style={{
                            paddingLeft: props.compact() ? 12 : 34,
                            paddingRight: 12,
                            paddingVertical: 11,
                            gap: 9,
                            borderTopWidth: 1,
                            borderTopColor: c().line2,
                            backgroundColor: c().soft2,
                          }}
                        >
                          <Row gap={14} wrap style={{ alignItems: "flex-start" }}>
                            <View style={{ flex: 1, minWidth: 200, gap: 2 }}>
                              <T size={10.5} color={c().faint}>令牌短指纹</T>
                              <Row gap={6} wrap>
                                <FingerprintChip fp={item().fingerprint} prefix="tok_" />
                                <T size={10.5} color={c().muted}>明文仅配对时显示一次</T>
                              </Row>
                            </View>
                            <View style={{ flex: 1, minWidth: 200, gap: 2 }}>
                              <T size={10.5} color={c().faint}>配对与通道</T>
                              <T size={11.5}>{`${formatPairedTime(item().createdUnix)} · 本机 Unix Socket · pv-mcp`}</T>
                            </View>
                          </Row>
                          <Row gap={14} wrap style={{ alignItems: "flex-start" }}>
                            <View style={{ flex: 1, minWidth: 200, gap: 2 }}>
                              <T size={10.5} color={c().faint}>最近操作与调用</T>
                              <T size={11.5}>{`${item().lastOpLabel} · 近 24h ${item().calls24h} 次 / 共 ${item().callsTotal} 次`}</T>
                            </View>
                            <View style={{ flex: 1, minWidth: 200, gap: 2 }}>
                              <T size={10.5} color={c().faint}>生效访问范围</T>
                              <T size={11.5}>{props.scopeSummary()}</T>
                            </View>
                          </Row>

                          <If when={item().paused}>
                            <Row gap={6} style={{ paddingHorizontal: 10, paddingVertical: 6, borderRadius: 7, backgroundColor: c().orangeSoft }}>
                              <Icon name="alert" size={13} tint={c().orange} />
                              <T size={11} color={c().orange} style={{ flex: 1 }}>
                                已暂停访问：此客户端的 MCP 请求会被立即拒绝，保留原配置以便随时点「恢复」。
                              </T>
                            </Row>
                          </If>

                          <Row gap={6} wrap style={{ paddingTop: 8, borderTopWidth: 1, borderTopColor: c().line2 }}>
                            <SoftActionBtn label="编辑名称与备注" icon="edit" onPress={() => openEditClientSheet(item())} />
                            <SoftActionBtn
                              label={auditOn() ? "已筛选日志（取消）" : "只看它的日志"}
                              icon="history"
                              tone={auditOn() ? "blue" : "default"}
                              onPress={() => toggleAuditFilter(item())}
                            />
                            <SoftActionBtn
                              label={item().paused ? "恢复访问" : "暂停访问"}
                              icon={item().paused ? "play" : "pause"}
                              tone={item().paused ? "blue" : "default"}
                              onPress={() => void togglePauseClient(item())}
                            />
                            <Spacer />
                            <SoftActionBtn label="撤销客户端" icon="trash" tone="danger" onPress={() => revokeClientWithConfirm(item())} />
                          </Row>
                        </View>
                      </If>
                    </View>
                  );
                }}
              </Each>
            </View>
          </If>
        </If>
      </Card>
    </View>
  );
}
