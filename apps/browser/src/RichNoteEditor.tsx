import { t, useLocale } from "./i18n";
import { useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import { command } from "./client";
import packageMetadata from "../package.json";
import { mergeRichSource, RichSnapshotGate } from "./rich-note-state";
type Item = { id: string; type: string; title: string; [key: string]: any };
const flushers = new Map<string, () => Promise<Item>>();
export async function flushRichNote(id: string): Promise<Item | undefined> {
  return flushers.get(id)?.();
}
function encode(bytes: Uint8Array) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 8192)
    s += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(s);
}
function references(node: any, out = new Set<string>()): Set<string> {
  if (!node || typeof node !== "object") return out;
  if (typeof node.attrs?.attachmentId === "string")
    out.add(node.attrs.attachmentId);
  for (const child of node.content ?? []) references(child, out);
  return out;
}
export function RichNoteEditor({
  item,
  editable = false,
  onChange,
}: {
  item: Item;
  editable?: boolean;
  onChange?: (item: Item) => void;
}) {
  const { language, theme } = useLocale();
  const frame = useRef<HTMLIFrameElement>(null);
  const previewSource = editable
    ? ""
    : JSON.stringify([item.noteFormat, item.noteDocument, item.note]);
  const token = useMemo(
    () => crypto.randomUUID(),
    [item.id, editable, language, previewSource],
  );
  const latest = useRef(item);
  if (!editable || latest.current.id !== item.id) latest.current = item;
  const callback = useRef(onChange);
  callback.current = onChange;
  const [error, setError] = useState("");
  useLayoutEffect(() => {
    let active = true;
    let initialized = false;
    let queue = Promise.resolve();
    let picking = 0;
    const snapshots = new RichSnapshotGate<Item>();
    let starting = false;
    let revision = 0;
    let activityAt = 0;
    const initial = latest.current;
    const initialSource =
      initial.noteFormat === "rich-v1"
        ? JSON.stringify({
            format: "rich-v1",
            document: initial.noteDocument,
            text: initial.note ?? "",
          })
        : (initial.note ?? "");
    const uploads = new Map<
      string,
      {
        name: string;
        mime: string;
        size: number;
        chunks: string[];
        received: number;
      }
    >();
    const send = (method: string, ...args: any[]) => {
      if (active)
        frame.current?.contentWindow?.postMessage(
          { channel: token, method, args },
          "*",
        );
    };
    if (editable)
      flushers.set(item.id, async () => {
        await queue;
        if (!initialized) return latest.current; // No editable document has been configured yet.
        if (uploads.size || picking) throw Error("Editor is busy");
        return snapshots.request((id) => send("snapshot", false, id));
      });
    const read = async (id: string) => {
      const value = await command({
        op: "attachment-read",
        id,
        noteId: item.id,
      });
      if (active) send("resource", id, value.data, value.mime);
      return value;
    };
    async function add(
      request: string,
      name: string,
      mime: string,
      data: string,
    ) {
      // A file picker/read may finish after navigation or lock disposed this owner.
      if (!active) return;
      // Files are owner-bound in the core; a new note must first be explicitly saved.
      const release = snapshots.hold();
      try {
        const meta = await command({
          op: "attachment-add",
          noteId: item.id,
          name,
          mime,
          data,
        });
        if (!active) return;
        send("resource", meta.id, data, mime);
        send("attachment", request, meta);
      } finally {
        release();
      }
    }
    async function receive(message: any) {
      if (!active) return;
      if (message.kind === "activity") {
        if (Date.now() - activityAt > 15000) {
          activityAt = Date.now();
          await command({ op: "activity" });
        }
      } else if (message.kind === "ready" && !initialized && !starting) {
        starting = true;
        for (const id of references(initial.noteDocument)) await read(id);
        send("configure", {
          sequence: 0,
          format: initial.noteFormat ?? "markdown",
          token: token,
          source: initialSource,
          expectedRevision: 0,
          editable,
          editing: editable,
          theme,
          chinese: language !== "en",
        });
        initialized = true;
      } else if (message.kind === "height" && Number.isFinite(message.height)) {
        if (frame.current)
          frame.current.style.height = `${Math.max(360, Math.min(200000, message.height))}px`;
      } else if (message.kind === "wheel" && Number.isFinite(message.deltaY)) {
        const container = frame.current?.closest(".editor-fields,.note-body");
        container?.scrollBy({
          top:
            message.deltaY *
            (message.deltaMode === 1
              ? 16
              : message.deltaMode === 2
                ? container.clientHeight
                : 1),
        });
      } else if (
        message.kind === "caret" &&
        editable &&
        Number.isFinite(message.y) &&
        Number.isFinite(message.height)
      ) {
        const container = frame.current?.closest(".editor-fields,.note-body");
        if (container && frame.current) {
          const outer = container.getBoundingClientRect();
          const y = frame.current.getBoundingClientRect().top + message.y;
          if (y + message.height > outer.bottom - 24)
            container.scrollBy({ top: y + message.height - outer.bottom + 24 });
          else if (y < outer.top + 24)
            container.scrollBy({ top: y - outer.top - 24 });
        }
      } else if (
        message.kind === "exportMarkdown" &&
        typeof message.markdown === "string"
      ) {
        const url = URL.createObjectURL(
          new Blob([message.markdown], { type: "text/markdown;charset=utf-8" }),
        );
        const link = document.createElement("a");
        link.href = url;
        link.download = "note.md";
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
      } else if (message.kind === "snapshot") {
        snapshots.accept(message.request, () => {
          const nextRevision = message.result?.revision;
          if (!Number.isInteger(nextRevision) || nextRevision < revision)
            throw Error("Stale snapshot");
          const next = mergeRichSource(
            latest.current,
            message.result?.source,
            initialSource,
          );
          revision = nextRevision;
          latest.current = next;
          callback.current?.(next);
          return next;
        });
      } else if (message.kind === "change" && editable) {
        if (!Number.isInteger(message.revision) || message.revision < revision)
          return;
        latest.current = mergeRichSource(latest.current, message.source);
        revision = message.revision;
        callback.current?.(latest.current);
      } else if (message.kind === "chooseFile" && editable) {
        const input = document.createElement("input");
        input.type = "file";
        if (message.images)
          input.accept = "image/png,image/jpeg,image/gif,image/webp";
        input.onchange = () => {
          void (async () => {
            const file = input.files?.[0];
            if (!file || !active) return;
            picking++;
            if (file.size > 25 * 1024 * 1024) throw Error("File too large");
            await add(
              message.request,
              file.name,
              file.type || "application/octet-stream",
              encode(new Uint8Array(await file.arrayBuffer())),
            );
          })()
            .catch(() => {
              setError(t("附件未添加。请先保存笔记，并检查文件大小。"));
              send("uploadError", message.request, t("附件未添加"));
            })
            .finally(() => {
              picking = Math.max(0, picking - 1);
            });
        };
        input.click();
      } else if (message.kind === "uploadStart" && editable) {
        if (
          uploads.size >= 4 ||
          !Number.isInteger(message.size) ||
          message.size < 0 ||
          message.size > 25 * 1024 * 1024
        )
          throw Error("Invalid upload");
        uploads.set(message.request, {
          name: message.name,
          mime: message.mime || "application/octet-stream",
          size: message.size,
          chunks: [],
          received: 0,
        });
      } else if (message.kind === "uploadChunk" && editable) {
        const pending = uploads.get(message.request);
        if (
          !pending ||
          typeof message.data !== "string" ||
          message.data.length > 262144
        )
          throw Error("Invalid chunk");
        const bytes = atob(message.data);
        pending.received += bytes.length;
        if (pending.received > pending.size) throw Error("Invalid size");
        pending.chunks.push(bytes);
      } else if (message.kind === "uploadFinish" && editable) {
        const pending = uploads.get(message.request);
        uploads.delete(message.request);
        if (!pending || pending.received !== pending.size)
          throw Error("Invalid upload");
        await add(
          message.request,
          pending.name,
          pending.mime,
          btoa(pending.chunks.join("")),
        );
      } else if (message.kind === "cancelUpload")
        uploads.delete(message.request);
      else if (message.kind === "saveAttachment") {
        const id = message.id;
        if (!references(latest.current.noteDocument).has(id))
          throw Error("Invalid attachment");
        const value = await read(id);
        if (!active) return;
        const url = URL.createObjectURL(
          new Blob(
            [Uint8Array.from(atob(value.data), (c) => c.charCodeAt(0))],
            { type: "application/octet-stream" },
          ),
        );
        const link = document.createElement("a");
        link.href = url;
        link.download = String(value.name).split(/[\\/]/).pop() || "attachment";
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
      } else if (message.kind === "failure") throw Error("Invalid note");
    }
    const listener = (event: MessageEvent) => {
      if (
        event.source !== frame.current?.contentWindow ||
        event.data?.channel !== token
      )
        return;
      queue = queue
        .then(() => receive(event.data))
        .catch(() => {
          if (active) setError(t("此操作未完成，原有资料保留。"));
        });
    };
    addEventListener("message", listener);
    return () => {
      active = false;
      uploads.clear();
      if (editable) flushers.delete(item.id);
      snapshots.close();
      removeEventListener("message", listener);
    };
  }, [item.id, editable, language, token]);
  return (
    <div>
      {error && <p role="alert">{error}</p>}
      <iframe
        key={token}
        ref={frame}
        title={editable ? t("编辑图文笔记") : t("图文笔记")}
        sandbox="allow-scripts"
        src={`note-editor.html?v=${encodeURIComponent(packageMetadata.version)}&protocol=2#${token}`}
        class="rich-note-frame"
      />
    </div>
  );
}
