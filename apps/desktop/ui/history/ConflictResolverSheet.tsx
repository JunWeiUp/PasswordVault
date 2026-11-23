// Zero-knowledge local C3 side-by-side parallel branch conflict resolver for concurrent secureNote edits.
// Preserves R9 attachment union guard and 30-day branch retention in entry_history.
import { cleanup, Scroll, signal, View } from "nsh";
import { Banner, Btn, openSheet, Pill, Row, SheetFooter, SheetTitle, T } from "../kit";
import {
  call,
  ensureFull,
  errorText,
  meshConflicts,
  onLock,
  phase,
  refreshItems,
  refreshMeshConflicts,
  toast,
  type MeshNoteConflict,
} from "../store";
import { c, MONO } from "../theme";
import { openItemHistory } from "./index";

export function openConflictResolver(noteId: string) {
  const cf = meshConflicts()[noteId];
  if (!cf) {
    void refreshMeshConflicts();
    return;
  }
  openSheet({
    width: 760,
    render: (close) => <ConflictResolverSheet conflict={cf} close={close} />,
  });
}

function ConflictResolverSheet(props: { conflict: MeshNoteConflict; close: () => void }) {
  const resolving = signal<"" | "local" | "remote" | "both">("");
  const err = signal("");
  let alive = true;
  cleanup(() => { alive = false; });
  cleanup(onLock(props.close));

  const cf = () => props.conflict;
  const localBody = () => String(cf().localItem?.note ?? "").trim() || "（空白正文）";
  const remoteBody = () => String(cf().remoteItem?.note ?? "").trim() || "（空白正文）";
  const formatTime = (ms: number) => (ms > 0 ? new Date(ms).toLocaleString() : "时间未知");

  const resolveWith = async (strategy: "local" | "remote" | "both") => {
    if (resolving() || phase() !== "unlocked") return;
    resolving.set(strategy);
    err.set("");
    try {
      await call({ op: "relay-mesh-resolve-conflict", id: cf().noteId, strategy });
      if (!alive || phase() !== "unlocked") return;
      await Promise.all([refreshItems(), refreshMeshConflicts()]);
      await ensureFull(cf().noteId);
      const label =
        strategy === "local"
          ? "已保留本机版本"
          : strategy === "remote"
            ? "已采用远端版本"
            : "已合并保留两版正文";
      toast(`${label}，另一分支可在版本历史保留 ${cf().retentionDays || 30} 天`);
      props.close();
    } catch (e) {
      if (alive) err.set(errorText(e));
    } finally {
      if (alive) resolving.set("");
    }
  };

  return (
    <View testID="conflict-resolver-sheet" style={{ gap: 12 }}>
      <SheetTitle
        title={`解决并行分支 · ${cf().title || "未命名笔记"}`}
        text={`冲突位置：${cf().section} · 捕获于 ${formatTime(cf().capturedAt)} · 全程本机零知识对比（不经过云端 AI）`}
      />

      <Row gap={6} wrap>
        <Pill tone="green">{cf().assetGuard || "两端附件引用已取并集保护（0 项丢失）"}</Pill>
        <Pill tone="blue">未选用分支保留 {cf().retentionDays || 30} 天</Pill>
        {(cf().autoMerged ?? []).map((note) => (
          <Pill tone="gray">C1 已自动合入：{note}</Pill>
        ))}
      </Row>

      <If when={err()}>
        <Banner tone="err" title="分支解决失败">{err()}</Banner>
      </If>

      <View style={{ flexDirection: "row", gap: 12 }}>
        <View style={{ flex: 1, minWidth: 0, borderWidth: 1, borderColor: c().blueLine, borderRadius: 10, backgroundColor: c().soft2, overflow: "hidden" }}>
          <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 12, paddingVertical: 8, backgroundColor: c().blueSoft, borderBottomWidth: 1, borderBottomColor: c().blueLine }}>
            <T size={12} weight="600" color={c().blue}>本机当前版本（{cf().localDevice}）</T>
            <T size={11} color={c().muted}>{cf().localItem?.updatedAt ? new Date(cf().localItem!.updatedAt).toLocaleTimeString() : ""}</T>
          </View>
          <Scroll style={{ maxHeight: 280 }} contentStyle={{ padding: 12, gap: 6 }}>
            <If when={(cf().localItem?.tags ?? []).length > 0}>
              <T size={11} color={c().muted}>标签：{(cf().localItem?.tags ?? []).join("、")}</T>
            </If>
            <T size={12.5} selectable color={c().ink} style={{ lineHeight: 20, fontFamily: MONO }}>{localBody()}</T>
          </Scroll>
        </View>

        <View style={{ flex: 1, minWidth: 0, borderWidth: 1, borderColor: c().line, borderRadius: 10, backgroundColor: c().soft2, overflow: "hidden" }}>
          <View style={{ flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 12, paddingVertical: 8, backgroundColor: c().orangeSoft, borderBottomWidth: 1, borderBottomColor: c().line }}>
            <T size={12} weight="600" color={c().orange}>并行分支版本（{cf().remoteDevice}）</T>
            <T size={11} color={c().muted}>{cf().remoteItem?.updatedAt ? new Date(cf().remoteItem!.updatedAt).toLocaleTimeString() : ""}</T>
          </View>
          <Scroll style={{ maxHeight: 280 }} contentStyle={{ padding: 12, gap: 6 }}>
            <If when={(cf().remoteItem?.tags ?? []).length > 0}>
              <T size={11} color={c().muted}>标签：{(cf().remoteItem?.tags ?? []).join("、")}</T>
            </If>
            <T size={12.5} selectable color={c().ink} style={{ lineHeight: 20, fontFamily: MONO }}>{remoteBody()}</T>
          </Scroll>
        </View>
      </View>

      <SheetFooter
        left={
          cf().localItem ? (
            <Btn
              label="查看完整版本历史"
              icon="history"
              disabled={!!resolving()}
              onPress={() => {
                const target = cf().localItem!;
                props.close();
                openItemHistory(target);
              }}
            />
          ) : undefined
        }
      >
        <Btn label="稍后处理" disabled={!!resolving()} onPress={props.close} />
        <Btn
          testID="conflict-keep-remote"
          label={resolving() === "remote" ? "应用中…" : "采用远端版本"}
          disabled={!!resolving()}
          onPress={() => void resolveWith("remote")}
        />
        <Btn
          testID="conflict-keep-both"
          label={resolving() === "both" ? "合并中…" : "合并保留两版"}
          disabled={!!resolving()}
          onPress={() => void resolveWith("both")}
        />
        <Btn
          testID="conflict-keep-local"
          label={resolving() === "local" ? "应用中…" : "保留本机版本"}
          kind="primary"
          disabled={!!resolving()}
          onPress={() => void resolveWith("local")}
        />
      </SheetFooter>
    </View>
  );
}
