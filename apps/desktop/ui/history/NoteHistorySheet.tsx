// Dedicated note version history modal: timeline with actor/milestone/summary/+N-M stats,
// arbitrary 2-version comparison, colored Markdown diff, historical preview, property diff,
// inline milestone snapshot, and non-destructive restore.
import { cleanup, signal, Scroll, View } from "nsh";
import { TextView } from "nsh/base";
import { Menu, type MenuItem } from "nsh/desktop";
import { Icon } from "../icons";
import { Banner, Btn, copySecret, Pill, Row, SheetFooter, SheetTitle, SmallAction, T, TextBox } from "../kit";
import { askEnableHistory, historyWarning } from "../recovery";
import { call, errorText, flush, items, load, now, onLock, phase, saveMilestone, type Item } from "../store";
import { c, MONO } from "../theme";
import { documentFor } from "../notes/model";
import { project } from "../notes/projection";
import {
  diffLines,
  diffNoteProperties,
  diffStats,
  isAiActor,
  noteToMarkdown,
  type NoteProperty,
} from "../notes/knowledge";

export type NoteRevision = {
  id: string;
  capturedAt: number;
  item: Item;
  deviceName?: string;
  deviceId?: string;
  actorType?: string;
  actor?: string;
  summary?: string;
  milestone?: boolean;
};

function formatRevTime(ms: number): string {
  const d = new Date(ms);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getMonth() + 1}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function actorMeta(r: NoteRevision): { label: string; tone: "blue" | "green" | "orange" | "gray" } {
  if (r.milestone) return { label: "里程碑", tone: "green" };
  if (r.actorType === "ai" || isAiActor(r.actor)) return { label: r.actor || "AI 更新", tone: "blue" };
  if (r.actorType === "restore") return { label: r.actor || "恢复版本", tone: "orange" };
  return { label: r.actor || r.deviceName || "手动编辑", tone: "gray" };
}

export function NoteHistorySheet(props: { item: Item; close: () => void; reopen: () => void }) {
  const revisions = signal<NoteRevision[]>([]);
  const total = signal(0);
  const enabled = signal(false);
  const selectedId = signal<string | null>(null);
  const compareId = signal<string | "prev" | "none">("prev");
  const filter = signal<"all" | "ai" | "milestone">("all");
  const mode = signal<"diff" | "preview" | "props">("diff");
  const busy = signal(false);
  const error = signal("");
  const confirmAct = signal<"restore" | "prune" | null>(null);
  const milestoneOpen = signal(false);
  const milestoneSummary = signal("");
  let alive = true;

  const clear = () => {
    revisions.set([]);
    selectedId.set(null);
  };
  cleanup(() => {
    alive = false;
    clear();
  });
  cleanup(
    onLock(() => {
      clear();
      props.close();
    }),
  );

  const run = async (fn: () => Promise<void>) => {
    if (busy()) return;
    busy.set(true);
    error.set("");
    try {
      await fn();
    } catch (e) {
      if (alive) error.set(errorText(e));
    } finally {
      if (alive) busy.set(false);
    }
  };

  const refresh = async (append = false) => {
    await flush();
    const status = await call({ op: "history-status" });
    const page = status.enabled
      ? await call<{ revisions: NoteRevision[]; total: number }>({
          op: "history-list",
          id: props.item.id,
          offset: append ? revisions().length : 0,
          limit: 40,
        })
      : { revisions: [], total: 0 };
    if (!alive) return;
    enabled.set(!!status.enabled);
    total.set(page.total ?? 0);
    const next: NoteRevision[] = append
      ? [...revisions(), ...(page.revisions ?? []).filter((r: NoteRevision) => !revisions().some((old) => old.id === r.id))]
      : page.revisions ?? [];
    revisions.set(next);
    if (next.length > 0 && (!selectedId() || !next.some((r) => r.id === selectedId()))) {
      selectedId.set(next[0].id);
      compareId.set("prev");
    }
  };

  void run(() => refresh());

  const current = () => items().find((i) => i.id === props.item.id) ?? props.item;
  const versionNumber = (rev: NoteRevision) => {
    const idx = revisions().findIndex((r) => r.id === rev.id);
    if (idx < 0) return 1;
    return Math.max(1, total() - idx);
  };

  const filtered = () => {
    const f = filter();
    return revisions().filter((r) => {
      if (f === "ai") return r.actorType === "ai" || isAiActor(r.actor);
      if (f === "milestone") return !!r.milestone;
      return true;
    });
  };

  const selectedRev = () =>
    revisions().find((r) => r.id === selectedId()) ?? filtered()[0] ?? revisions()[0] ?? null;

  const baseRev = (): NoteRevision | null => {
    const sel = selectedRev();
    if (!sel) return null;
    const target = compareId();
    if (target === "none") return null;
    if (target === "prev") {
      const idx = revisions().findIndex((r) => r.id === sel.id);
      return idx >= 0 && idx + 1 < revisions().length ? revisions()[idx + 1] : null;
    }
    return revisions().find((r) => r.id === target) ?? null;
  };

  const prevOf = (rev: NoteRevision): NoteRevision | null => {
    const idx = revisions().findIndex((r) => r.id === rev.id);
    return idx >= 0 && idx + 1 < revisions().length ? revisions()[idx + 1] : null;
  };

  const mdCache = new Map<string, string>();
  const revMd = (rev: NoteRevision | null): string => {
    if (!rev?.item) return "";
    let cached = mdCache.get(rev.id);
    if (cached === undefined) {
      cached = noteToMarkdown(rev.item);
      mdCache.set(rev.id, cached);
    }
    return cached;
  };

  const compareMenu = (): MenuItem[] => {
    const sel = selectedRev();
    const list = revisions().filter((r) => !sel || r.id !== sel.id);
    return [
      { label: "自动对比上一版", checked: compareId() === "prev", onSelect: () => compareId.set("prev") },
      { label: "不对比（查看全文基线）", checked: compareId() === "none", onSelect: () => compareId.set("none") },
      ...(list.length > 0 ? [{ type: "separator" as const }] : []),
      ...list.map((r): MenuItem => ({
        label: `对比 v${versionNumber(r)} · ${r.summary || actorMeta(r).label} (${formatRevTime(r.capturedAt)})`,
        checked: compareId() === r.id,
        onSelect: () => compareId.set(r.id),
      })),
    ];
  };

  const submitMilestone = () => {
    const text = milestoneSummary().trim();
    if (!text) return;
    void run(async () => {
      const ok = await saveMilestone(props.item.id, text);
      if (ok && alive) {
        milestoneSummary.set("");
        milestoneOpen.set(false);
        mdCache.clear();
        await refresh();
      }
    });
  };

  const executeConfirm = () =>
    void run(async () => {
      const act = confirmAct();
      const sel = selectedRev();
      await flush();
      if (!alive || phase() !== "unlocked") return;
      if (act === "restore" && sel) {
        await call({ op: "history-restore", id: props.item.id, revisionId: sel.id, time: now() });
        await load();
        if (alive) props.close();
      } else if (act === "prune") {
        await call({ op: "history-prune", id: props.item.id, keepMilestones: true });
        mdCache.clear();
        clear();
        await refresh();
      }
      if (alive) confirmAct.set(null);
    });

  const metadataDiffRows = (oldItem: Item | undefined, newItem: Item | undefined) => {
    const rows: { key: string; before: string; after: string; kind: "added" | "removed" | "changed" | "same" }[] = [];
    const pushMeta = (label: string, a: string, b: string) => {
      if (!a && !b) return;
      const kind = !a && b ? "added" : a && !b ? "removed" : a !== b ? "changed" : "same";
      rows.push({ key: label, before: a, after: b, kind });
    };
    pushMeta("标题", oldItem?.title ?? "", newItem?.title ?? "");
    pushMeta("目录", oldItem?.category ?? "", newItem?.category ?? "");
    pushMeta("Slug", oldItem?.slug ?? "", newItem?.slug ?? "");
    pushMeta("标签", (oldItem?.tags ?? []).join("、"), (newItem?.tags ?? []).join("、"));
    const propRows = diffNoteProperties(
      oldItem?.noteProperties as NoteProperty[] | undefined,
      newItem?.noteProperties as NoteProperty[] | undefined,
    );
    return [...rows, ...propRows];
  };

  const diffRows = () => {
    const sel = selectedRev();
    if (!sel) return [];
    const base = baseRev();
    if (!base) {
      const lines = revMd(sel).split("\n");
      return lines.map((text, idx) => ({ type: "ctx" as const, text, lineNo: idx + 1 }));
    }
    return diffLines(revMd(base), revMd(sel));
  };

  const changedProps = () => {
    const sel = selectedRev();
    const base = baseRev();
    if (!sel || !base) return [];
    return metadataDiffRows(base.item, sel.item).filter((r) => r.kind !== "same");
  };

  const previewDoc = (rev: NoteRevision) => {
    if (rev.item?.noteFormat === "rich-v1" && rev.item?.noteDocument?.type === "doc") {
      return project(rev.item.noteDocument);
    }
    return project(documentFor({ id: rev.item?.id ?? props.item.id, note: revMd(rev), noteFormat: "plain" }));
  };

  return (
    <View testID="note-history-sheet" style={{ gap: 12 }}>
      <Row style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <View style={{ flex: 1, minWidth: 0 }}>
          <SheetTitle
            title={`笔记版本历史 · ${current().title || "未命名笔记"}`}
            text="每次 AI 自动更新、里程碑快照和手动编辑均独立加密保存；恢复始终生成新版本。"
          />
        </View>
        <If when={!current().isDeleted}>
          <Btn
            testID="history-inline-milestone-btn"
            label="保存里程碑"
            icon="plus"
            disabled={busy()}
            onPress={() => milestoneOpen.update((v) => !v)}
          />
        </If>
      </Row>

      <If when={milestoneOpen()}>
        <Row gap={8} style={{ padding: 10, borderRadius: 8, backgroundColor: c().soft2, borderWidth: 1, borderColor: c().line }}>
          <View style={{ flex: 1 }}>
            <TextBox
              testID="history-milestone-input"
              value={milestoneSummary()}
              onChange={(v) => milestoneSummary.set(v)}
              placeholder="输入里程碑说明（如：2026 Q3 调仓归档、体检复查完成）"
              autoFocus
              onSubmit={submitMilestone}
            />
          </View>
          <Btn testID="history-milestone-submit" label="保存" kind="primary" disabled={busy() || !milestoneSummary().trim()} onPress={submitMilestone} />
          <Btn label="取消" onPress={() => { milestoneOpen.set(false); milestoneSummary.set(""); }} />
        </Row>
      </If>

      <If when={error()}>
        <Banner tone="err" title={error()} style={{ marginBottom: 0 }} />
      </If>

      <If
        when={enabled()}
        else={
          <View style={{ gap: 10 }}>
            <Banner tone="warn" title="完整版本历史尚未启用" style={{ marginBottom: 0 }}>
              {historyWarning}（提示：点击上方「保存里程碑」或允许 AI 自动保存笔记时，也会自动启用完整历史。）
            </Banner>
            <Row>
              <Btn
                label="立即启用完整历史…"
                kind="primary"
                disabled={busy()}
                onPress={() => askEnableHistory(props.reopen)}
              />
            </Row>
          </View>
        }
      >
        {/* Filter bar */}
        <Row gap={6} style={{ justifyContent: "space-between" }}>
          <Row gap={4}>
            {([["all", "全部"], ["ai", "AI 自动更新"], ["milestone", "里程碑"]] as const).map(([k, label]) => (
              <View
                role="button"
                testID={`history-filter-${k}`}
                accessibilityState={{ selected: filter() === k }}
                onPress={() => filter.set(k)}
                style={{
                  paddingHorizontal: 10,
                  paddingVertical: 4,
                  borderRadius: 6,
                  backgroundColor: filter() === k ? c().blueSoft : c().soft2,
                  borderWidth: 1,
                  borderColor: filter() === k ? c().blueLine : c().line,
                  cursor: "pointer",
                }}
              >
                <T size={11.5} weight={filter() === k ? "600" : "400"} color={filter() === k ? c().blue : c().muted}>
                  {label}
                </T>
              </View>
            ))}
          </Row>
          <T size={11.5} color={c().faint}>
            共 {total()} 个加密版本{revisions().length < total() ? `（已加载 ${revisions().length} 个）` : ""}
          </T>
        </Row>

        {/* Two-column timeline + diff/preview viewer */}
        <View
          style={{
            flexDirection: "row",
            height: 440,
            borderWidth: 1,
            borderColor: c().line,
            borderRadius: 10,
            overflow: "hidden",
            backgroundColor: c().surface,
          }}
        >
          {/* Left timeline */}
          <View style={{ width: 268, borderRightWidth: 1, borderRightColor: c().line, backgroundColor: c().list }}>
            <Scroll style={{ flex: 1 }} contentStyle={{ padding: 8, gap: 6 }}>
              <If when={filtered().length > 0} else={<T size={12} color={c().faint} style={{ padding: 12 }}>当前筛选下没有版本记录。</T>}>
                <Each of={filtered()} key={(r) => r.id}>
                  {(rev) => {
                    const active = () => selectedRev()?.id === rev().id;
                    const meta = () => actorMeta(rev());
                    const stats = () => {
                      const prev = prevOf(rev());
                      return prev ? diffStats(revMd(prev), revMd(rev())) : null;
                    };
                    return (
                      <View
                        role="button"
                        testID={`history-rev-${rev().id}`}
                        accessibilityState={{ selected: active() }}
                        onPress={() => {
                          selectedId.set(rev().id);
                          confirmAct.set(null);
                        }}
                        style={{
                          padding: 9,
                          borderRadius: 8,
                          borderWidth: 1,
                          borderColor: active() ? c().blueLine : "transparent",
                          backgroundColor: active() ? c().blueSoft : c().surface,
                          gap: 4,
                          cursor: "pointer",
                        }}
                        hoverStyle={active() ? undefined : { backgroundColor: c().soft }}
                      >
                        <Row gap={6}>
                          <T mono size={11.5} weight="600" color={active() ? c().blue : c().ink}>
                            v{versionNumber(rev())}
                          </T>
                          <Pill tone={meta().tone}>{meta().label}</Pill>
                          <View style={{ flex: 1 }} />
                          <T size={10.5} color={c().faint}>{formatRevTime(rev().capturedAt)}</T>
                        </Row>
                        <T size={12} weight="500" color={c().ink} lines={2}>
                          {rev().summary || (versionNumber(rev()) === 1 ? "初始版本" : "内容已更新")}
                        </T>
                        <If when={!!stats()}>
                          <Row gap={6}>
                            <T mono size={10.5} color={c().green}>+{stats()!.add}</T>
                            <T mono size={10.5} color={c().red}>-{stats()!.del}</T>
                          </Row>
                        </If>
                      </View>
                    );
                  }}
                </Each>
              </If>
              <If when={revisions().length < total()}>
                <Btn label="加载更多版本" disabled={busy()} onPress={() => void run(() => refresh(true))} />
              </If>
            </Scroll>
          </View>

          {/* Right inspector */}
          <View style={{ flex: 1, minWidth: 0 }}>
            <If
              when={selectedRev()}
              else={<View style={{ flex: 1, alignItems: "center", justifyContent: "center" }}><T size={12.5} color={c().faint}>选择左侧版本查看变更对比或当时预览</T></View>}
            >
              {/* Top strip: compare baseline + 3 mode tabs */}
              <Row
                gap={8}
                style={{
                  paddingHorizontal: 14,
                  paddingVertical: 9,
                  borderBottomWidth: 1,
                  borderBottomColor: c().line,
                  backgroundColor: c().soft2,
                  justifyContent: "space-between",
                }}
              >
                <View
                  role="button"
                  testID="history-compare-picker"
                  accessibilityLabel="选择对比基线版本"
                  onPress={(e: any) => void Menu.popup(compareMenu(), e?.pagePosition)}
                  style={{
                    flexDirection: "row",
                    alignItems: "center",
                    gap: 5,
                    paddingHorizontal: 8,
                    paddingVertical: 4,
                    borderRadius: 6,
                    borderWidth: 1,
                    borderColor: c().line,
                    backgroundColor: c().surface,
                    cursor: "pointer",
                  }}
                  hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blueLine }}
                >
                  <T size={11.5} color={c().ink2}>
                    {baseRev()
                      ? `对比 v${versionNumber(baseRev()!)} → v${versionNumber(selectedRev()!)}`
                      : `基线：v${versionNumber(selectedRev()!)}`}
                  </T>
                  <Icon name="chevd" size={10} tint={c().muted} />
                </View>

                <View style={{ flexDirection: "row", backgroundColor: c().field, borderRadius: 7, padding: 2 }}>
                  {([["diff", "变更对比"], ["preview", "当时预览"], ["props", "属性变更"]] as const).map(([m, label]) => (
                    <View
                      role="button"
                      testID={`history-mode-${m}`}
                      accessibilityState={{ selected: mode() === m }}
                      onPress={() => mode.set(m)}
                      style={{
                        paddingHorizontal: 10,
                        paddingVertical: 3,
                        borderRadius: 5,
                        backgroundColor: mode() === m ? c().surface : "transparent",
                        cursor: "pointer",
                      }}
                    >
                      <T size={11.5} weight={mode() === m ? "600" : "400"} color={mode() === m ? c().blue : c().muted}>
                        {label}
                      </T>
                    </View>
                  ))}
                </View>
              </Row>

              {/* Mode content */}
              <Scroll style={{ flex: 1 }} contentStyle={{ padding: 14, gap: 10 }}>
                <If when={mode() === "diff"}>
                  <If when={!baseRev()}>
                    <T size={11.5} color={c().muted}>当前为最早基线版本，以下展示该版本完整 Markdown 内容：</T>
                  </If>
                  <If when={changedProps().length > 0}>
                    <View style={{ padding: 10, borderRadius: 8, backgroundColor: c().soft2, borderWidth: 1, borderColor: c().line, gap: 4 }}>
                      <T size={11} weight="600" color={c().muted}>元信息与属性变更</T>
                      {changedProps().map((p) => (
                        <Row gap={8}>
                          <T size={11.5} color={c().ink2} style={{ width: 90 }} lines={1}>{p.key}</T>
                          <T size={11.5} color={c().red} style={{ textDecorationLine: "line-through" }} lines={1}>{p.before || "（空）"}</T>
                          <T size={11} color={c().faint}>→</T>
                          <T size={11.5} color={c().green} weight="500" style={{ flex: 1 }} lines={1}>{p.after || "（空）"}</T>
                        </Row>
                      ))}
                    </View>
                  </If>
                  <View
                    testID="note-history-diff"
                    style={{
                      borderWidth: 1,
                      borderColor: c().line,
                      borderRadius: 8,
                      overflow: "hidden",
                      backgroundColor: c().surface,
                    }}
                  >
                    {diffRows().map((line) => (
                      <View
                        style={{
                          flexDirection: "row",
                          gap: 8,
                          paddingHorizontal: 10,
                          paddingVertical: 2,
                          backgroundColor:
                            line.type === "add"
                              ? c().greenSoft
                              : line.type === "del"
                                ? c().redSoft
                                : "transparent",
                        }}
                      >
                        <T mono size={10.5} color={c().faint} style={{ width: 28, textAlign: "right" }}>
                          {String(line.lineNo)}
                        </T>
                        <T
                          mono
                          size={11.5}
                          weight="600"
                          color={line.type === "add" ? c().green : line.type === "del" ? c().red : c().faint}
                          style={{ width: 12 }}
                        >
                          {line.type === "add" ? "+" : line.type === "del" ? "-" : " "}
                        </T>
                        <T
                          mono
                          size={12}
                          selectable
                          color={line.type === "add" ? c().green : line.type === "del" ? c().red : c().ink2}
                          style={{ flex: 1 }}
                        >
                          {line.text || " "}
                        </T>
                      </View>
                    ))}
                  </View>
                </If>

                <If when={mode() === "preview"}>
                  <Row style={{ justifyContent: "space-between", paddingBottom: 6, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
                    <View style={{ gap: 2 }}>
                      <T size={16} weight="700">{selectedRev()!.item?.title || "未命名笔记"}</T>
                      <T size={11} color={c().muted}>
                        {[selectedRev()!.item?.category || "未分类", selectedRev()!.item?.slug ? `/${selectedRev()!.item.slug}` : ""].filter(Boolean).join(" · ")}
                      </T>
                    </View>
                    <SmallAction
                      icon="copy"
                      label="复制此版本 Markdown"
                      tint={c().blue}
                      onPress={() => void copySecret(revMd(selectedRev()), "历史版本 Markdown")}
                    />
                  </Row>
                  <TextView document={previewDoc(selectedRev()!)} links="report" onLinkPress={() => {}} />
                </If>

                <If when={mode() === "props"}>
                  <View style={{ borderWidth: 1, borderColor: c().line, borderRadius: 8, overflow: "hidden" }}>
                    <Row style={{ paddingHorizontal: 10, paddingVertical: 7, backgroundColor: c().soft2, borderBottomWidth: 1, borderBottomColor: c().line }}>
                      <T size={11} weight="600" color={c().muted} style={{ width: 110 }}>字段 / 属性</T>
                      <T size={11} weight="600" color={c().muted} style={{ flex: 1 }}>基线版本</T>
                      <T size={11} weight="600" color={c().muted} style={{ flex: 1 }}>当前所选 v{versionNumber(selectedRev()!)}</T>
                      <T size={11} weight="600" color={c().muted} style={{ width: 54, textAlign: "right" }}>状态</T>
                    </Row>
                    {metadataDiffRows(baseRev()?.item, selectedRev()!.item).map((r) => (
                      <Row style={{ paddingHorizontal: 10, paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
                        <T size={12} color={c().ink2} style={{ width: 110 }} lines={1}>{r.key}</T>
                        <T size={12} color={c().muted} style={{ flex: 1 }} lines={2}>{r.before || "—"}</T>
                        <T size={12} color={c().ink} style={{ flex: 1 }} lines={2}>{r.after || "—"}</T>
                        <View style={{ width: 54, alignItems: "flex-end" }}>
                          <Pill tone={r.kind === "added" ? "green" : r.kind === "removed" ? "red" : r.kind === "changed" ? "orange" : "gray"}>
                            {r.kind === "added" ? "新增" : r.kind === "removed" ? "删除" : r.kind === "changed" ? "修改" : "未变"}
                          </Pill>
                        </View>
                      </Row>
                    ))}
                  </View>
                </If>
              </Scroll>
            </If>
          </View>
        </View>

        <If when={confirmAct()}>
          <Banner
            tone="warn"
            title={confirmAct() === "restore" ? `恢复为 v${selectedRev() ? versionNumber(selectedRev()!) : ""}？` : "清理旧版本（保留里程碑）？"}
            style={{ marginBottom: 0 }}
            actions={
              <>
                <Btn label="取消" disabled={busy()} onPress={() => confirmAct.set(null)} />
                <Btn
                  testID="note-history-confirm-act"
                  label={confirmAct() === "restore" ? "确认恢复（生成新版本）" : "确认清理"}
                  kind={confirmAct() === "prune" ? "dangerSolid" : "primary"}
                  disabled={busy()}
                  onPress={executeConfirm}
                />
              </>
            }
          >
            {confirmAct() === "restore"
              ? "当前笔记内容会继续保存在历史中，恢复结果会写入为最新的版本，不会覆盖过往记录。"
              : "将保留当前最新版本以及所有已标记的里程碑版本，仅删除其余中间版本。"}
          </Banner>
        </If>
      </If>

      <SheetFooter
        left={
          <If when={enabled() && !current().isDeleted && revisions().length > 1}>
            <Btn label="清理旧版本…" kind="danger" disabled={busy()} onPress={() => confirmAct.set("prune")} />
          </If>
        }
      >
        <If when={enabled() && !!selectedRev() && !current().isDeleted}>
          <Btn
            testID="note-history-restore-btn"
            label={`恢复为 v${versionNumber(selectedRev()!)}（生成新版本）`}
            kind="primary"
            disabled={busy()}
            onPress={() => confirmAct.set("restore")}
          />
        </If>
        <Btn label="关闭" disabled={busy()} onPress={props.close} />
      </SheetFooter>
    </View>
  );
}
