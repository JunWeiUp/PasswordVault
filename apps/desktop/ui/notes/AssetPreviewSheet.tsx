// Read-only local preview modal for encrypted note binary assets (inline image Lightbox + Quick Look + local text excerpt).
import { cleanup, Image, signal, Scroll, View } from "nsh";
import { Btn, OptionRow, Pill, Row, SheetFooter, SheetTitle, T, Toggle, openSheet } from "../kit";
import { desktopCapabilities } from "../native";
import { onLock, phase, toast } from "../store";
import { c } from "../theme";
import {
  aiAssetTextEnabled,
  assetErrorText,
  assetReadinessBadge,
  exportAssetPlaintext,
  fetchAssetPreviewInfo,
  formatAssetSize,
  launchAssetQuickLook,
  openExternalAsset,
  readImageOriginal,
  readImageThumbnail,
  requestRemoteAsset,
  toggleAiAssetText,
  type AssetPreviewInfo,
  type NoteAssetMeta,
} from "../api/noteAssets";

export function openAssetPreviewSheet(noteId: string, asset: NoteAssetMeta) {
  openSheet({
    width: asset.mime?.startsWith("image/") ? 720 : 640,
    render: (close) => <AssetPreviewSheet noteId={noteId} asset={asset} close={close} />,
  });
}

function AssetPreviewSheet(props: { noteId: string; asset: NoteAssetMeta; close: () => void }) {
  const info = signal<AssetPreviewInfo | null>(null);
  const loading = signal(true);
  const error = signal("");
  const isImage = () => (info()?.mime ?? props.asset.mime ?? "").startsWith("image/");
  const imageSrc = signal("");
  const imageLod = signal<"l2" | "l3" | "">("");
  const loadingOriginal = signal(false);
  let alive = true;
  cleanup(() => { alive = false; });
  cleanup(onLock(props.close));

  void fetchAssetPreviewInfo(props.noteId, props.asset.id)
    .then((parsed) => {
      if (!alive || phase() !== "unlocked") return;
      info.set(parsed);
      const remote = parsed.state === "remote" || parsed.state === "downloading" || parsed.state === "failed";
      if ((parsed.mime ?? props.asset.mime ?? "").startsWith("image/") && !remote) {
        void readImageThumbnail(props.noteId, props.asset.id)
          .then((res) => {
            if (!alive || phase() !== "unlocked") return;
            imageSrc.set(res.dataUrl);
            imageLod.set(res.lod);
          })
          .catch(() => {});
      }
    })
    .catch((e: unknown) => {
      if (alive) error.set(assetErrorText(e));
    })
    .finally(() => {
      if (alive) loading.set(false);
    });

  const loadOriginalImage = async () => {
    if (loadingOriginal() || imageLod() === "l3") return;
    loadingOriginal.set(true);
    try {
      const full = await readImageOriginal(props.noteId, props.asset.id);
      if (alive && phase() === "unlocked" && full) {
        imageSrc.set(full);
        imageLod.set("l3");
        toast("已加载 100% 原图");
      }
    } catch (e) {
      toast(assetErrorText(e));
    } finally {
      if (alive) loadingOriginal.set(false);
    }
  };

  const meta = (): AssetPreviewInfo => info() ?? props.asset;
  const ready = () => assetReadinessBadge(meta());
  const isRemote = () => meta().state === "remote" || meta().state === "downloading" || meta().state === "failed";
  const aiOn = () => aiAssetTextEnabled(props.noteId, props.asset.id);
  const pulling = signal(false);
  const pullRemote = async () => {
    if (pulling()) return;
    pulling.set(true);
    try {
      await requestRemoteAsset(props.noteId, meta());
    } finally {
      if (alive) pulling.set(false);
    }
  };
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
        text={`${formatAssetSize(props.asset.size)} · ${isRemote() ? "云端元数据就绪（按需拉取原文件）" : `${meta().blobShort ?? "SQLCipher"}${meta().chunks ? `（${meta().chunks} × 64 KiB 分块加密）` : ""}`}`}
      />
      <View style={{ backgroundColor: c().soft2, borderWidth: 1, borderColor: c().line, borderRadius: 10, padding: 12, gap: 8 }}>
        <Row style={{ justifyContent: "space-between" }} wrap gap={8}>
          <Row gap={6}>
            <T size={12.5} weight="600">本地只读预览</T>
            <Pill tone={ready().tone}>{ready().label}</Pill>
          </Row>
          <Pill tone={meta().excerptCached ? "blue" : "green"}>
            {meta().excerptCached ? "本地加密摘录 · 预计算缓存" : "0400 只读 · 不进 Spotlight / Time Machine"}
          </Pill>
        </Row>
        <If when={!loading()} else={<T size={12} color={c().muted}>正在读取加密预览…</T>}>
          <If when={!error()} else={<T size={12} color={c().red}>{error()}</T>}>
            <If when={isImage() && imageSrc()}>
              <View style={{ gap: 8 }}>
                <View style={{ alignItems: "center", justifyContent: "center", borderRadius: 8, overflow: "hidden", backgroundColor: c().surface, borderWidth: 1, borderColor: c().line2, padding: 8 }}>
                  <Image
                    src={imageSrc()}
                    style={{ width: "100%", height: 300, objectFit: "contain" }}
                  />
                </View>
                <Row style={{ justifyContent: "space-between" }} gap={8}>
                  <Pill tone={imageLod() === "l3" ? "ok" : "info"}>
                    {imageLod() === "l3" ? "L3 · 100% 原图" : "L2 · 缩略图预览"}
                  </Pill>
                  <If when={imageLod() === "l2"}>
                    <Btn
                      label={loadingOriginal() ? "正在加载原图…" : "加载 100% 原图"}
                      disabled={loadingOriginal()}
                      onPress={() => void loadOriginalImage()}
                    />
                  </If>
                </Row>
              </View>
            </If>
            <If when={!isImage() || !imageSrc()}>
              <If when={meta().excerpt} else={
                <T size={12} color={c().muted}>
                  {isRemote()
                    ? "当前仅同步了元数据，尚未拉取原始加密分块。点击下方「拉取原文件」后即可查看或外部打开。"
                    : meta().canExtractText
                      ? "未能提取到文本内容（可能为扫描版 PDF），可点击下方使用系统快速查看或第三方应用打开。"
                      : isImage()
                        ? "正在解码本地加密图片…"
                        : "此文件为非文本二进制格式，可点击下方使用系统快速查看或第三方应用打开。"}
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
        </If>
        <If when={isRemote()}>
          <T size={11} color={c().muted}>
            门控原因：{ready().reason || "原文件尚未下载到本机，暂禁用快速查看、第三方打开与明文导出。"}
          </T>
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
          note="SQLCipher 认证索引 + 外置 blobs/ 64 KiB 分块加密（> 512 KiB 附件默认跨设备按需拉取）"
        >
          <Pill tone="blue">{isRemote() ? "云端按需（blobs/）" : meta().storage === "pvblob-v1" ? "blobs/ 分块加密" : "SQLCipher 内联"}</Pill>
        </OptionRow>
      </View>
      <SheetFooter
        left={
          <Row gap={6}>
            <Btn label="另存明文副本…" icon="down" disabled={isRemote()} onPress={() => exportAssetPlaintext(props.noteId, props.asset)} />
            <If when={!meta().blockedExternal}>
              <Btn label="系统快速查看" icon="eye" disabled={isRemote()} onPress={() => void launchQuickLook()} />
            </If>
          </Row>
        }
      >
        <Btn label="关闭" onPress={props.close} />
        <If
          when={!isRemote()}
          else={
            <Btn
              label={pulling() ? "拉取中…" : "拉取原文件"}
              icon="down"
              kind="primary"
              disabled={pulling()}
              onPress={() => void pullRemote()}
            />
          }
        >
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
        </If>
      </SheetFooter>
    </View>
  );
}
