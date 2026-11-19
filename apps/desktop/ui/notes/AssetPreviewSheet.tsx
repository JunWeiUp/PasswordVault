// Read-only local preview modal for encrypted note binary assets (Quick Look + local text excerpt).
import { cleanup, signal, Scroll, View } from "nsh";
import { Btn, OptionRow, Pill, Row, SheetFooter, SheetTitle, T, Toggle, openSheet } from "../kit";
import { desktopCapabilities } from "../native";
import { onLock, phase, toast } from "../store";
import { c } from "../theme";
import {
  aiAssetTextEnabled,
  assetErrorText,
  exportAssetPlaintext,
  fetchAssetPreviewInfo,
  formatAssetSize,
  launchAssetQuickLook,
  openExternalAsset,
  toggleAiAssetText,
  type AssetPreviewInfo,
  type NoteAssetMeta,
} from "../api/noteAssets";

export function openAssetPreviewSheet(noteId: string, asset: NoteAssetMeta) {
  openSheet({
    width: 640,
    render: (close) => <AssetPreviewSheet noteId={noteId} asset={asset} close={close} />,
  });
}

function AssetPreviewSheet(props: { noteId: string; asset: NoteAssetMeta; close: () => void }) {
  const info = signal<AssetPreviewInfo | null>(null);
  const loading = signal(true);
  const error = signal("");
  let alive = true;
  cleanup(() => { alive = false; });
  cleanup(onLock(props.close));

  void fetchAssetPreviewInfo(props.noteId, props.asset.id)
    .then((parsed) => {
      if (!alive || phase() !== "unlocked") return;
      info.set(parsed);
    })
    .catch((e: unknown) => {
      if (alive) error.set(assetErrorText(e));
    })
    .finally(() => {
      if (alive) loading.set(false);
    });

  const meta = (): AssetPreviewInfo => info() ?? props.asset;
  const aiOn = () => aiAssetTextEnabled(props.noteId, props.asset.id);
  const launchQuickLook = async () => {
    try {
      await launchAssetQuickLook(props.noteId, props.asset.id);
      toast("已以 0400 只读模式打开系统快速查看（Quick Look）");
    } catch (e) {
      toast(assetErrorText(e));
    }
  };

  return (
    <View testID="asset-preview-sheet" style={{ gap: 12 }}>
      <SheetTitle
        title={`快速查看 · ${props.asset.name}`}
        text={`${formatAssetSize(props.asset.size)} · ${meta().blobShort ?? "SQLCipher"}${meta().chunks ? `（${meta().chunks} × 64 KiB 分块加密）` : ""}`}
      />
      <View style={{ backgroundColor: c().soft2, borderWidth: 1, borderColor: c().line, borderRadius: 10, padding: 12, gap: 8 }}>
        <Row style={{ justifyContent: "space-between" }} wrap gap={8}>
          <T size={12.5} weight="600">本地只读预览（内存中提取文本摘录）</T>
          <Pill tone="green">0400 只读 · 不进 Spotlight / Time Machine</Pill>
        </Row>
        <If when={!loading()} else={<T size={12} color={c().muted}>正在本地解密提取预览…</T>}>
          <If when={!error()} else={<T size={12} color={c().red}>{error()}</T>}>
            <If when={meta().excerpt} else={
              <T size={12} color={c().muted}>
                {meta().canExtractText ? "未能提取到文本内容（可能为扫描版 PDF），可点击下方使用系统快速查看或第三方应用打开。" : "此文件为非文本二进制格式，可点击下方使用系统快速查看或第三方应用打开。"}
              </T>
            }>
              <Scroll style={{ maxHeight: 220 }}>
                <T size={12} selectable color={c().ink} style={{ lineHeight: 19 }}>{meta().excerpt}</T>
              </Scroll>
              <If when={(meta().totalChars ?? 0) > 4000}>
                <T size={11} color={c().muted}>仅预览前 4,000 字（全文共 {meta().totalChars} 字）</T>
              </If>
            </If>
          </If>
        </If>
      </View>
      <View style={{ borderWidth: 1, borderColor: c().line, borderRadius: 10, paddingHorizontal: 14, backgroundColor: c().surface }}>
        <If when={desktopCapabilities.ai && meta().canExtractText}>
          <Toggle
            title="允许 AI 读取提取纯文本（note_read_asset）"
            note="默认关闭；开启后仅在本地提取纯文本返回给 Agent，绝不发送原始 PDF / Word 二进制。"
            checked={aiOn()}
            onChange={() => void toggleAiAssetText(props.noteId, props.asset)}
          />
        </If>
        <OptionRow
          title="存储方式"
          note="SQLCipher 认证索引 + 外置 blobs/ 64 KiB 分块加密（单文件上限 100 MB，去重且历史版本共享引用）"
        >
          <Pill tone="blue">{meta().storage === "pvblob-v1" ? "blobs/ 分块加密" : "SQLCipher 内联"}</Pill>
        </OptionRow>
      </View>
      <SheetFooter
        left={
          <Row gap={6}>
            <Btn label="另存明文副本…" icon="down" onPress={() => exportAssetPlaintext(props.noteId, props.asset)} />
            <If when={!meta().blockedExternal}>
              <Btn label="系统快速查看" icon="eye" onPress={() => void launchQuickLook()} />
            </If>
          </Row>
        }
      >
        <Btn label="关闭" onPress={props.close} />
        <If when={!meta().blockedExternal}>
          <Btn
            label="用第三方应用打开"
            icon="globe"
            kind="primary"
            onPress={() => {
              props.close();
              void openExternalAsset(props.noteId, props.asset);
            }}
          />
        </If>
      </SheetFooter>
    </View>
  );
}
