// In-note top banner for externally opened encrypted assets (live session & dirty write-back).
import { cleanup, effect, signal, View } from "nsh";
import { Banner, Btn, Row } from "../kit";
import { call, flush, items, now, phase, refreshItems, toast, type Item } from "../store";
import { clone, plainText, type Node } from "./model";
import {
  assetErrorText,
  bumpAssetSessions,
  bumpNoteAssets,
  closeExternalSession,
  formatDelta,
  listExternalAssetSessions,
  replaceAttachmentInDoc,
  sessionsTick,
  writeBackExternalSession,
  type ExternalAssetSession,
} from "../api/noteAssets";

export function NoteExternalEditBanner(props: { item: Item }) {
  const sessions = signal<ExternalAssetSession[]>([]);
  const busyId = signal("");
  let alive = true;
  cleanup(() => { alive = false; });

  const loadSessions = async () => {
    if (phase() !== "unlocked") {
      sessions.set([]);
      return;
    }
    try {
      const list = await listExternalAssetSessions(props.item.id);
      if (alive) sessions.set(list);
    } catch {
      if (alive) sessions.set([]);
    }
  };

  effect(() => {
    props.item.id;
    sessionsTick();
    if (phase() !== "unlocked") {
      sessions.set([]);
      return;
    }
    void loadSessions();
    const timer = setInterval(() => {
      if (alive && phase() === "unlocked" && sessions().length > 0) {
        void loadSessions();
      }
    }, 1500);
    cleanup(() => clearInterval(timer));
  });

  const writeBack = async (s: ExternalAssetSession) => {
    if (busyId()) return;
    busyId.set(s.sessionId);
    try {
      await flush();
      const nextMeta = await writeBackExternalSession(s.sessionId);
      const currentItem = items().find((i) => i.id === props.item.id) ?? props.item;
      const doc: Node = currentItem.noteFormat === "rich-v1" && currentItem.noteDocument
        ? clone(currentItem.noteDocument)
        : { type: "doc", content: [{ type: "paragraph" }] };
      const replaced = replaceAttachmentInDoc(doc, s.attachmentId, nextMeta);
      if (!replaced) {
        doc.content = [
          ...(doc.content ?? []),
          {
            type: nextMeta.mime.startsWith("image/") ? "vaultImage" : "vaultAttachment",
            attrs: nextMeta.mime.startsWith("image/")
              ? { attachmentId: nextMeta.id, name: nextMeta.name, mime: nextMeta.mime, width: 600, caption: "" }
              : { attachmentId: nextMeta.id, name: nextMeta.name, mime: nextMeta.mime, size: nextMeta.size },
          },
        ];
      }
      const actor = `外部编辑回写 · ${s.appName}`;
      const summary = `外部修改回写「${nextMeta.name}」`;
      const updated: Item = {
        ...currentItem,
        noteFormat: "rich-v1",
        noteDocument: doc,
        note: plainText(doc),
        lastActor: actor,
        lastSummary: summary,
        updatedAt: now(),
      };
      await call({
        op: "save",
        richNotes: true,
        item: updated,
        historyMeta: { actorType: "user", actor, summary, milestone: false },
      });
      await refreshItems();
      bumpAssetSessions();
      bumpNoteAssets();
      toast(`已将「${nextMeta.name}」按 64 KiB 分块重新加密写回并生成新版本`);
    } catch (e) {
      toast(assetErrorText(e));
    } finally {
      if (alive) busyId.set("");
    }
  };

  const dismiss = async (s: ExternalAssetSession) => {
    try {
      await closeExternalSession(s.sessionId);
      bumpAssetSessions();
      toast("已忽略外部修改并清除临时明文文件");
    } catch (e) {
      toast(assetErrorText(e));
    }
  };

  return (
    <If when={!props.item.isDeleted && sessions().length > 0}>
      <View testID="note-ext-banner" style={{ gap: 8, marginBottom: 12 }}>
        {sessions().map((s) =>
          s.dirty ? (
            <View testID="note-ext-writeback-banner">
              <Banner
                tone="warn"
                icon="sync"
                title={`检测到「${s.name}」已在 ${s.appName} 中修改（${formatDelta(s.deltaBytes)} · SHA-256 已更新）`}
                style={{ marginBottom: 0 }}
                actions={
                  <Row gap={6}>
                    <Btn
                      testID="asset-writeback-btn"
                      label={busyId() === s.sessionId ? "正在写回…" : "加密写回并生成新版本"}
                      icon="check"
                      kind="primary"
                      disabled={busyId() === s.sessionId}
                      onPress={() => void writeBack(s)}
                    />
                    <Btn
                      testID="asset-dismiss-btn"
                      label="忽略并清理"
                      kind="ghost"
                      disabled={busyId() === s.sessionId}
                      onPress={() => void dismiss(s)}
                    />
                  </Row>
                }
              >
                确认写回将按 64 KiB 分块重新加密存入 blobs/ 并生成新版本，旧版资产继续保留在历史记录中。
              </Banner>
            </View>
          ) : (
            <View testID="note-ext-live-banner">
              <Banner
                tone="info"
                icon="globe"
                title={`外部打开中：正在用「${s.appName}」查看 ${s.name}`}
                style={{ marginBottom: 0 }}
                actions={
                  <Row gap={6}>
                    <Btn label="检查修改" icon="sync" onPress={() => void loadSessions()} />
                    <Btn label="结束并清理临时文件" kind="ghost" onPress={() => void dismiss(s)} />
                  </Row>
                }
              >
                位于 0700 防 Spotlight 索引 / 防 Time Machine 备份会话目录 · 锁库或退出自动清除临时明文
              </Banner>
            </View>
          ),
        )}
      </View>
    </If>
  );
}
