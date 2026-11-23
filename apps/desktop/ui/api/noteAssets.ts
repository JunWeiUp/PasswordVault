// Typed TS API adapter & pure helpers for encrypted note binary assets (blobs/, <= 100 MB).
// Keeps formatting, app-recommendation, AST updates, and UI workflows in TypeScript
// so UI/UX changes deploy via --ui-only in seconds without touching Rust.
import { signal } from "nsh";
import { Files } from "passwordvault/native";
import { aiSettings, change as aiChange } from "../ai";
import { confirm } from "../kit";
import { coreApi, errorText, phase, toast, vaultInstance } from "../store";
import { c } from "../theme";
import { attachmentsNative, relayNative } from "./nativeBridge";

export type AssetReadiness = "ready" | "remote" | "downloading" | "failed";

export type NoteAssetMeta = {
  id: string;
  noteId: string;
  name: string;
  mime: string;
  size: number;
  storage?: string;
  blobId?: string;
  blobShort?: string;
  chunks?: number;
  state?: AssetReadiness;
  sourceDevice?: string;
  errorReason?: string;
  hasCachedExcerpt?: boolean;
  hasThumb?: boolean;
  thumbWidth?: number;
  thumbHeight?: number;
  canExtractText?: boolean;
  blockedExternal?: boolean;
};

export type AssetPreviewInfo = NoteAssetMeta & {
  excerpt?: string;
  totalChars?: number;
  excerptCached?: boolean;
  remoteOnly?: boolean;
};

export type ImageThumbResult = {
  dataUrl: string;
  width?: number;
  height?: number;
  lod: "l2" | "l3";
  cached?: boolean;
};

export type ExternalAssetSession = {
  sessionId: string;
  noteId: string;
  attachmentId: string;
  name: string;
  mime: string;
  appName: string;
  initialSize: number;
  currentSize: number;
  deltaBytes: number;
  dirty: boolean;
  openedAtUnix: number;
};

export const sessionsTick = signal(0);
export const assetsTick = signal(0);

export function bumpNoteAssets() {
  assetsTick.update((n) => n + 1);
}

export function bumpAssetSessions() {
  sessionsTick.update((n) => n + 1);
}

export function formatAssetSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function formatDelta(delta: number): string {
  if (delta === 0) return "大小不变";
  const sign = delta > 0 ? "+" : "-";
  return `${sign}${formatAssetSize(Math.abs(delta))}`;
}

export function assetBadge(name: string, mime: string): { label: string; fg: string; bg: string } {
  const ext = name.includes(".") ? name.split(".").pop()!.toLowerCase() : "";
  if (ext === "pdf" || mime === "application/pdf") {
    return { label: "PDF", fg: c().red, bg: c().redSoft };
  }
  if (ext === "docx" || ext === "doc" || mime.includes("word")) {
    return { label: ext.toUpperCase() || "DOC", fg: c().blue, bg: c().blueSoft };
  }
  if (ext === "xlsx" || ext === "xls" || ext === "csv" || mime.includes("sheet") || mime.includes("excel")) {
    return { label: ext.toUpperCase() || "XLS", fg: c().green, bg: c().greenSoft };
  }
  if (ext === "pptx" || ext === "ppt" || mime.includes("presentation")) {
    return { label: "PPT", fg: c().orange, bg: c().orangeSoft };
  }
  if (mime.startsWith("image/") || ["png", "jpg", "jpeg", "gif", "webp"].includes(ext)) {
    return { label: "IMG", fg: c().orange, bg: c().orangeSoft };
  }
  return { label: (ext || "FILE").slice(0, 4).toUpperCase(), fg: c().ink2, bg: c().soft };
}

export function recommendedApps(name: string, mime: string): { label: string; app: string }[] {
  const ext = name.includes(".") ? name.split(".").pop()!.toLowerCase() : "";
  if (ext === "pdf" || mime === "application/pdf") {
    return [
      { label: "用 预览（Preview）打开", app: "Preview" },
      { label: "用 Adobe Acrobat 打开", app: "Adobe Acrobat" },
      { label: "用 PDF Expert 打开", app: "PDF Expert" },
    ];
  }
  if (ext === "docx" || ext === "doc") {
    return [
      { label: "用 Microsoft Word 打开", app: "Microsoft Word" },
      { label: "用 WPS Office 打开", app: "wpsoffice" },
      { label: "用 Pages 文稿打开", app: "Pages" },
    ];
  }
  if (ext === "xlsx" || ext === "xls" || ext === "csv") {
    return [
      { label: "用 Microsoft Excel 打开", app: "Microsoft Excel" },
      { label: "用 WPS Office 打开", app: "wpsoffice" },
      { label: "用 Numbers 表格打开", app: "Numbers" },
    ];
  }
  if (ext === "pptx" || ext === "ppt") {
    return [
      { label: "用 Microsoft PowerPoint 打开", app: "Microsoft PowerPoint" },
      { label: "用 Keynote 讲演打开", app: "Keynote" },
    ];
  }
  return [{ label: "用系统默认应用打开", app: "" }];
}

const ASSET_ERRORS: Record<string, string> = {
  BlockedExecutable: "出于安全限制，不允许直接用第三方应用打开可执行文件或脚本（.app / .command / .sh / .dmg 等）。",
  AssetTooLarge: "单个加密资产文件不能超过 100 MB。",
  OpenFailed: "未能启动所选外部应用，请确认应用已安装或改用默认应用打开。",
  Unchanged: "临时文件内容未发生变化，无需写回。",
  SessionNotFound: "临时编辑会话已结束或已清理。",
  RelayDisconnected: "同步网络未连接，请先在「设置 › 同步」恢复连接后再拉取云端附件。",
  PeerOffline: "附件来源设备当前离线，待对方上线后可立即拉取。",
  Unsupported: "该附件尚未下载到本机，请先点击「拉取下载」。",
};

export function assetReadinessBadge(asset: NoteAssetMeta): {
  label: string;
  tone: "green" | "blue" | "orange" | "red";
  reason?: string;
} {
  switch (asset.state) {
    case "remote":
      return {
        label: "云端按需",
        tone: "blue",
        reason: asset.sourceDevice
          ? `仅同步元信息与摘录，原文件位于设备「${asset.sourceDevice}」`
          : "仅同步元信息与摘录，点击拉取后可打开原文件",
      };
    case "downloading":
      return { label: "拉取中…", tone: "blue", reason: "正在通过端到端加密通道按需下载" };
    case "failed":
      return {
        label: "拉取失败",
        tone: "red",
        reason: asset.errorReason ? assetErrorText(asset.errorReason) : "拉取中断，可点击重试",
      };
    default:
      return { label: "本地就绪", tone: "green" };
  }
}

export function assetErrorText(e: unknown): string {
  const code = String(e).replace(/^Error:\s*/, "");
  return ASSET_ERRORS[code] ?? errorText(e);
}

export function collectReferencedIds(node: any, out: Set<string>) {
  if (!node || typeof node !== "object") return;
  if ((node.type === "vaultAttachment" || node.type === "vaultImage") && node.attrs?.attachmentId) {
    out.add(String(node.attrs.attachmentId));
  }
  if (Array.isArray(node.content)) {
    for (const child of node.content) collectReferencedIds(child, out);
  }
}

export function replaceAttachmentInDoc(
  node: any,
  oldId: string,
  nextMeta: { id: string; name: string; mime: string; size: number },
): boolean {
  if (!node || typeof node !== "object") return false;
  let changed = false;
  if ((node.type === "vaultAttachment" || node.type === "vaultImage") && node.attrs?.attachmentId === oldId) {
    node.attrs.attachmentId = nextMeta.id;
    node.attrs.name = nextMeta.name;
    node.attrs.mime = nextMeta.mime;
    if (node.type === "vaultAttachment") node.attrs.size = nextMeta.size;
    changed = true;
  }
  if (Array.isArray(node.content)) {
    for (const child of node.content) {
      if (replaceAttachmentInDoc(child, oldId, nextMeta)) changed = true;
    }
  }
  return changed;
}

export function removeAttachmentFromDoc(node: any, attachmentId: string): boolean {
  if (!node || typeof node !== "object" || !Array.isArray(node.content)) return false;
  let changed = false;
  const kept: any[] = [];
  for (const child of node.content) {
    if ((child?.type === "vaultAttachment" || child?.type === "vaultImage") && child?.attrs?.attachmentId === attachmentId) {
      changed = true;
      continue;
    }
    if (removeAttachmentFromDoc(child, attachmentId)) changed = true;
    kept.push(child);
  }
  node.content = kept.length > 0 ? kept : node.type === "doc" ? [{ type: "paragraph" }] : kept;
  return changed;
}

export function aiAssetTextEnabled(noteId: string, attachmentId: string): boolean {
  return aiSettings().aiAccessNoteAssetText?.[noteId]?.[attachmentId] === true;
}

export async function toggleAiAssetText(noteId: string, asset: NoteAssetMeta) {
  const next = !aiAssetTextEnabled(noteId, asset.id);
  const current = aiSettings().aiAccessNoteAssetText ?? {};
  await aiChange({
    op: "configure",
    aiAccessNoteAssetText: {
      ...current,
      [noteId]: { ...(current[noteId] ?? {}), [asset.id]: next },
    },
  });
  toast(next ? `已允许 AI 通过 note_read_asset 读取「${asset.name}」提取纯文本` : `已关闭「${asset.name}」的 AI 文本读取`);
}

// --- Pure TS asset classification & formatting (kept out of Rust) ---

const BLOCKED_EXTERNAL_EXTS = new Set([
  "app", "command", "sh", "bash", "zsh", "csh", "ksh", "fish", "dmg", "pkg", "mpkg",
  "exe", "msi", "bat", "cmd", "ps1", "vbs", "wsf", "scr", "com", "jar", "jnlp",
  "workflow", "action", "scpt", "applescript", "osa", "pkgproj", "iso", "img",
]);

const EXTRACTABLE_EXTS = new Set([
  "pdf", "docx", "xlsx", "pptx", "txt", "md", "markdown", "json", "yaml", "yml",
  "toml", "csv", "tsv", "xml", "html", "htm", "log", "ini", "conf", "cfg", "sql",
  "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "kt", "swift", "c", "h", "cpp",
]);

export function fileExt(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot >= 0 ? name.slice(dot + 1).toLowerCase() : "";
}

export function isBlockedExternalAsset(name: string): boolean {
  return BLOCKED_EXTERNAL_EXTS.has(fileExt(name));
}

export function canExtractAssetText(name: string, mime: string): boolean {
  const m = mime.toLowerCase();
  if (
    m === "application/pdf"
    || m.startsWith("text/")
    || m === "application/json"
    || m === "application/xml"
    || m.includes("wordprocessingml")
    || m.includes("spreadsheetml")
    || m.includes("presentationml")
  ) {
    return true;
  }
  return EXTRACTABLE_EXTS.has(fileExt(name));
}

export function formatBlobShort(blobId?: string): string | undefined {
  if (!blobId) return undefined;
  return blobId.length > 10
    ? `blobs/${blobId.slice(0, 4)}…${blobId.slice(-4)}.pvblob`
    : `blobs/${blobId}.pvblob`;
}

export function enrichNoteAsset(raw: Record<string, any>): NoteAssetMeta {
  const name = String(raw.name ?? "");
  const mime = String(raw.mime ?? "application/octet-stream");
  const blobId = typeof raw.blobId === "string" ? raw.blobId : undefined;
  const rawState = typeof raw.state === "string" ? raw.state : "ready";
  const state: AssetReadiness =
    rawState === "remote" || rawState === "downloading" || rawState === "failed" ? rawState : "ready";
  return {
    id: String(raw.id ?? ""),
    noteId: String(raw.noteId ?? ""),
    name,
    mime,
    size: Number(raw.size ?? 0),
    storage: typeof raw.storage === "string" ? raw.storage : undefined,
    blobId,
    blobShort: formatBlobShort(blobId),
    chunks: typeof raw.chunks === "number" ? raw.chunks : undefined,
    state,
    sourceDevice: typeof raw.sourceDevice === "string" ? raw.sourceDevice : undefined,
    errorReason: typeof raw.errorReason === "string" ? raw.errorReason : undefined,
    hasCachedExcerpt: raw.hasCachedExcerpt === true,
    hasThumb: raw.hasThumb === true,
    thumbWidth: typeof raw.thumbWidth === "number" ? raw.thumbWidth : undefined,
    thumbHeight: typeof raw.thumbHeight === "number" ? raw.thumbHeight : undefined,
    canExtractText: canExtractAssetText(name, mime),
    blockedExternal: isBlockedExternalAsset(name),
  };
}

// --- Thin native boundary wrappers ---

export async function listNoteAssets(noteId: string): Promise<NoteAssetMeta[]> {
  const parsed = await coreApi.noteAttachmentsList(noteId);
  return Array.isArray(parsed?.attachments) ? parsed.attachments.map(enrichNoteAsset) : [];
}

export async function getBlobStorageStatus() {
  return await coreApi.noteAttachmentsStatus();
}

export async function readImageThumbnail(noteId: string, attachmentId: string): Promise<ImageThumbResult> {
  const fn = attachmentsNative.readThumbnail;
  if (typeof fn === "function") {
    const raw = await fn(vaultInstance, noteId, attachmentId);
    const parsed = JSON.parse(raw) as ImageThumbResult;
    if (parsed?.dataUrl) return parsed;
  }
  const full = await attachmentsNative.readImage(vaultInstance, noteId, attachmentId);
  return { dataUrl: full, lod: "l3", cached: false };
}

export async function readImageOriginal(noteId: string, attachmentId: string): Promise<string> {
  return await attachmentsNative.readImage(vaultInstance, noteId, attachmentId);
}

export async function requestRemoteAsset(noteId: string, asset: NoteAssetMeta): Promise<boolean> {
  try {
    const fn = relayNative.requestBlob;
    if (typeof fn !== "function") {
      toast("当前运行环境暂不支持按需拉取远端附件");
      return false;
    }
    await fn(vaultInstance, noteId, asset.id, asset.sourceDevice ?? null);
    bumpNoteAssets();
    toast(`已向设备发送「${asset.name}」按需拉取请求`);
    return true;
  } catch (e) {
    bumpNoteAssets();
    toast(assetErrorText(e));
    return false;
  }
}

export async function fetchAssetPreviewInfo(noteId: string, attachmentId: string): Promise<AssetPreviewInfo> {
  const list = await listNoteAssets(noteId);
  const meta = list.find((a) => a.id === attachmentId);
  if (!meta) throw new Error("InvalidData");
  if (!meta.canExtractText || meta.size > 32 * 1024 * 1024) {
    return { ...meta, excerpt: undefined, totalChars: 0, remoteOnly: meta.state === "remote" };
  }
  try {
    const raw = await attachmentsNative.extractText?.(vaultInstance, noteId, attachmentId, 4000);
    if (!raw) return { ...meta, excerpt: undefined, totalChars: 0, remoteOnly: meta.state === "remote" };
    const extracted = JSON.parse(raw) as {
      text?: string | null;
      totalChars?: number;
      cached?: boolean;
      remote?: boolean;
    };
    return {
      ...meta,
      excerpt: extracted.text ?? undefined,
      totalChars: extracted.totalChars ?? 0,
      excerptCached: extracted.cached === true,
      remoteOnly: extracted.remote === true || meta.state === "remote",
    };
  } catch {
    return { ...meta, excerpt: undefined, totalChars: 0, remoteOnly: meta.state === "remote" };
  }
}

export async function launchAssetQuickLook(noteId: string, attachmentId: string): Promise<void> {
  if (!attachmentsNative.quickLook) throw new Error("Unsupported");
  await attachmentsNative.quickLook(vaultInstance, noteId, attachmentId);
}

export async function listExternalAssetSessions(noteId: string): Promise<ExternalAssetSession[]> {
  if (!attachmentsNative.listSessions) return [];
  const raw = await attachmentsNative.listSessions(noteId);
  const parsed = JSON.parse(raw);
  return Array.isArray(parsed?.sessions) ? parsed.sessions : [];
}

export async function writeBackExternalSession(
  sessionId: string,
): Promise<{ id: string; name: string; mime: string; size: number }> {
  if (!attachmentsNative.writeBackSession) throw new Error("Unsupported");
  const raw = await attachmentsNative.writeBackSession(vaultInstance, sessionId);
  const res = JSON.parse(raw);
  return res.meta as { id: string; name: string; mime: string; size: number };
}

export async function closeExternalSession(sessionId: string): Promise<void> {
  await attachmentsNative.closeSession?.(sessionId);
}

export async function openExternalAsset(noteId: string, asset: NoteAssetMeta, appName?: string) {
  try {
    if (!attachmentsNative.openExternal) throw new Error("Unsupported");
    await attachmentsNative.openExternal(vaultInstance, noteId, asset.id, appName || null);
    bumpAssetSessions();
    toast(`已解密到 0700 防索引临时会话并用「${appName || "默认应用"}」打开，锁库或退出自动清除`);
  } catch (e) {
    toast(assetErrorText(e));
  }
}

export function exportAssetPlaintext(noteId: string, asset: NoteAssetMeta) {
  confirm({
    title: `另存「${asset.name}」明文副本？`,
    text: "导出的文件将不再受 PasswordVault 加密保护，也不会在锁库时自动清理。请保存到你信任的位置。",
    ok: "选择保存位置…",
    onConfirm: () => {
      void (async () => {
        try {
          const ext = asset.name.includes(".") ? [asset.name.split(".").pop()!] : [];
          const dest = await Files.pickSave("另存加密资产明文副本", asset.name, ext);
          if (!dest || phase() !== "unlocked") return;
          if (!attachmentsNative.exportPlaintext) throw new Error("Unsupported");
          await attachmentsNative.exportPlaintext(vaultInstance, noteId, asset.id, dest);
          toast(`已导出明文副本：${asset.name}`);
        } catch (e) {
          toast(assetErrorText(e));
        }
      })();
    },
  });
}
