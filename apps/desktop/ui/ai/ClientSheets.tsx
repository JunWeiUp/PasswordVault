// Modal sheets for editing, cleaning up, and batch-managing paired AI clients.
import { cleanup, Scroll, signal, View } from "nsh";
import { Icon } from "../icons";
import { Banner, Btn, IconBtn, Pill, Row, SheetFooter, SheetTitle, Spacer, T, TextBox, confirm, openSheet } from "../kit";
import { onLock, toast } from "../store";
import { c, fs, radius } from "../theme";
import {
  clientStateLabel,
  clientSubline,
  countAiClientStates,
  filterAiClients,
  findDuplicateClientNames,
  formatPairedTime,
  type AiClientFilter,
  type AiClientView,
} from "../api/aiClients";
import { change } from "./index";
import {
  Checkbox,
  FingerprintChip,
  SoftActionBtn,
  StatusDot,
  auditClientId,
  expandedClientId,
  pruneNotesAfterRevoke,
  revokeClientWithConfirm,
  saveClientNote,
  stateTone,
  toggleAuditFilter,
  togglePauseClient,
} from "./ClientBadges";

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

