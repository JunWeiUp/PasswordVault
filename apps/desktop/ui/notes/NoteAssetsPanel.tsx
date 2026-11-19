// Unified encrypted blobs/ asset list for a note. Pure logic/API lives in ui/api/noteAssets.ts,
// preview modal in AssetPreviewSheet.tsx, and top write-back banner in NoteExternalEditBanner.tsx.
import { cleanup, effect, signal, View } from "nsh";
import { Menu } from "nsh/desktop";
import { Attachments, Files } from "passwordvault/native";
import { Icon } from "../icons";
import { Btn, IconBtn, Row, T, confirm } from "../kit";
import { desktopCapabilities } from "../native";
import { edit, flush, items, phase, toast, vaultInstance, type Item } from "../store";
import { c } from "../theme";
import { clone, plainText, type Node } from "./model";
import { openAssetPreviewSheet } from "./AssetPreviewSheet";
import {
  aiAssetTextEnabled,
  assetBadge,
  assetErrorText,
  assetsTick,
  bumpNoteAssets,
  collectReferencedIds,
  exportAssetPlaintext,
  listNoteAssets,
  openExternalAsset,
  recommendedApps,
  removeAttachmentFromDoc,
  toggleAiAssetText,
  formatAssetSize,
  type NoteAssetMeta,
} from "../api/noteAssets";

export { NoteExternalEditBanner } from "./NoteExternalEditBanner";
export { bumpAssetSessions, bumpNoteAssets, formatAssetSize, type ExternalAssetSession, type NoteAssetMeta } from "../api/noteAssets";

export function NoteAssetsSection(props: { item: Item; editable: boolean }) {
  const stored = signal<NoteAssetMeta[]>([]);
  const importing = signal(false);
  let alive = true;
  cleanup(() => { alive = false; });

  const loadAssets = async () => {
    if (phase() !== "unlocked" || props.item.noteSummary) return;
    try {
      const list = await listNoteAssets(props.item.id);
      if (alive) stored.set(list);
    } catch {
      if (alive) stored.set([]);
    }
  };

  effect(() => {
    props.item.id;
    props.item.updatedAt;
    assetsTick();
    void loadAssets();
  });

  // Show only attachments currently referenced by this note (historical revisions retain older IDs silently).
  const activeAssets = (): NoteAssetMeta[] => {
    const refs = new Set<string>();
    collectReferencedIds(props.item.noteDocument, refs);
    if (refs.size === 0) return [];
    return stored().filter((a) => refs.has(a.id));
  };

  const importFromPicker = async () => {
    if (!props.editable || importing() || phase() !== "unlocked") return;
    importing.set(true);
    try {
      await flush();
      const path = await Files.pickOpen("导入加密资产（PDF / Word / Excel / 图片，上限 100 MB）", []);
      if (!path || !alive || phase() !== "unlocked") return;
      const raw = await Attachments.importFile(vaultInstance, props.item.id, path);
      const meta = JSON.parse(raw) as { id: string; name: string; mime: string; size: number };
      const currentItem = items().find((i) => i.id === props.item.id) ?? props.item;
      const doc: Node = currentItem.noteFormat === "rich-v1" && currentItem.noteDocument
        ? clone(currentItem.noteDocument)
        : {
            type: "doc",
            content: currentItem.note
              ? [{ type: "paragraph", content: [{ type: "text", text: String(currentItem.note) }] }]
              : [],
          };
      const isImg = meta.mime.startsWith("image/");
      const node: Node = {
        type: isImg ? "vaultImage" : "vaultAttachment",
        attrs: isImg
          ? { attachmentId: meta.id, name: meta.name, mime: meta.mime, width: 600, caption: "" }
          : { attachmentId: meta.id, name: meta.name, mime: meta.mime, size: meta.size },
      };
      doc.content = [...(doc.content ?? []), node];
      edit(props.item.id, (d) => {
        if (d.noteFormat !== "rich-v1" && !d.noteOriginal) {
          d.noteOriginal = { format: d.noteFormat ?? "plain", source: String(d.note ?? "") };
        }
        d.noteFormat = "rich-v1";
        d.noteDocument = doc;
        d.note = plainText(doc);
        d.lastActor = "手动编辑 · 我";
        d.lastSummary = `导入加密资产「${meta.name}」`;
      });
      await flush();
      bumpNoteAssets();
      toast(`已按 64 KiB 分块加密导入「${meta.name}」并插入正文`);
    } catch (e) {
      toast(assetErrorText(e));
    } finally {
      if (alive) importing.set(false);
    }
  };

  const removeAsset = (asset: NoteAssetMeta) => {
    confirm({
      title: `从当前笔记移除「${asset.name}」？`,
      text: "仅移除当前正文中的资产引用；历史版本中的旧附件仍受引用计数保护，可随时从版本历史找回。",
      ok: "移除引用",
      danger: true,
      onConfirm: () => {
        void (async () => {
          const currentItem = items().find((i) => i.id === props.item.id) ?? props.item;
          if (!currentItem.noteDocument) return;
          const doc = clone(currentItem.noteDocument);
          if (!removeAttachmentFromDoc(doc, asset.id)) return;
          edit(props.item.id, (d) => {
            d.noteDocument = doc;
            d.note = plainText(doc);
            d.lastActor = "手动编辑 · 我";
            d.lastSummary = `移除资产「${asset.name}」`;
          });
          await flush();
          bumpNoteAssets();
          toast(`已移除「${asset.name}」的引用`);
        })();
      },
    });
  };

  const openWithMenu = (asset: NoteAssetMeta, pos?: { x: number; y: number }) => {
    const appItems = asset.blockedExternal
      ? []
      : recommendedApps(asset.name, asset.mime).map((entry) => ({
          label: entry.label,
          onSelect: () => void openExternalAsset(props.item.id, asset, entry.app || undefined),
        }));
    const menuItems: any[] = [
      ...appItems,
      ...(appItems.length ? [{ separator: true }] : []),
      { label: "快速查看（只读零残留）", onSelect: () => openAssetPreviewSheet(props.item.id, asset) },
      { label: "另存明文副本…", onSelect: () => exportAssetPlaintext(props.item.id, asset) },
    ];
    void Menu.popup(menuItems, pos);
  };

  return (
    <If when={!props.item.isDeleted}>
      <View
        testID="note-assets-section"
        style={{
          marginTop: 18,
          paddingTop: 12,
          borderTopWidth: 1,
          borderTopColor: c().line,
          gap: 10,
        }}
      >
        <Row style={{ justifyContent: "space-between" }} wrap gap={8}>
          <Row gap={6}>
            <Icon name="paper" size={13} tint={c().muted} />
            <T size={12} weight="600" color={c().muted}>
              {activeAssets().length > 0
                ? `加密资产附件 · ${activeAssets().length} 个（≤ 100 MB · blobs/ 分块加密）`
                : "加密资产附件"}
            </T>
          </Row>
          <If when={props.editable}>
            <Btn
              testID="note-import-asset-btn"
              label={importing() ? "导入中…" : "导入 PDF / Word / 表格…"}
              icon="plus"
              kind="ghost"
              tooltip="支持导入 PDF / Word / Excel / 图片（单文件上限 100 MB，64 KiB 分块加密存于 blobs/）"
              disabled={importing()}
              onPress={() => void importFromPicker()}
            />
          </If>
        </Row>

        <If when={activeAssets().length > 0}>
          <View style={{ gap: 7 }}>
            {activeAssets().map((asset) => {
              const badge = assetBadge(asset.name, asset.mime);
              const aiOn = () => aiAssetTextEnabled(props.item.id, asset.id);
              return (
                <View
                  testID={`note-asset-row-${asset.id}`}
                  style={{
                    flexDirection: "row",
                    alignItems: "center",
                    flexWrap: "wrap",
                    gap: 10,
                    paddingHorizontal: 12,
                    paddingVertical: 10,
                    borderRadius: 9,
                    borderWidth: 1,
                    borderColor: c().line,
                    backgroundColor: c().soft2,
                  }}
                >
                  <View
                    style={{
                      width: 36,
                      height: 36,
                      borderRadius: 8,
                      alignItems: "center",
                      justifyContent: "center",
                      backgroundColor: badge.bg,
                      flexShrink: 0,
                    }}
                  >
                    <T mono size={10} weight="700" color={badge.fg}>{badge.label}</T>
                  </View>
                  <View style={{ flex: 1, minWidth: 210, gap: 2 }}>
                    <T size={12.5} weight="600" lines={1}>{asset.name}</T>
                    <T size={11} color={c().muted} lines={1}>
                      {formatAssetSize(asset.size)} · {asset.blobShort ?? "SQLCipher"}
                      {asset.chunks ? ` · ${asset.chunks} 块加密` : ""}
                      {asset.blockedExternal ? " · 可执行文件仅限只读导出" : ""}
                    </T>
                  </View>
                  <Row gap={5} wrap>
                    <If when={desktopCapabilities.ai && asset.canExtractText}>
                      <Btn
                        testID={`asset-ai-toggle-${asset.id}`}
                        label={aiOn() ? "AI 可读文本" : "AI 禁读"}
                        icon="spark"
                        kind={aiOn() ? "default" : "ghost"}
                        tooltip={aiOn() ? "已允许 Agent 通过 note_read_asset 读取本地提取纯文本" : "默认关闭；点击开启后 Agent 可读取本地提取纯文本（不传原文件）"}
                        onPress={() => void toggleAiAssetText(props.item.id, asset)}
                      />
                    </If>
                    <Btn label="预览" icon="eye" onPress={() => openAssetPreviewSheet(props.item.id, asset)} />
                    <If when={!asset.blockedExternal}>
                      <Btn
                        label="打开"
                        icon="globe"
                        kind="primary"
                        onPress={() => void openExternalAsset(props.item.id, asset)}
                      />
                    </If>
                    <IconBtn
                      icon="chevd"
                      label="选择打开方式"
                      size={12}
                      onPress={(e: any) => openWithMenu(asset, e?.pagePosition)}
                    />
                    <IconBtn
                      icon="down"
                      label={`另存明文副本 ${asset.name}`}
                      size={12}
                      onPress={() => exportAssetPlaintext(props.item.id, asset)}
                    />
                    <If when={props.editable}>
                      <IconBtn
                        icon="trash"
                        label={`移除 ${asset.name}`}
                        size={12}
                        onPress={() => removeAsset(asset)}
                      />
                    </If>
                  </Row>
                </View>
              );
            })}
          </View>
        </If>
      </View>
    </If>
  );
}
