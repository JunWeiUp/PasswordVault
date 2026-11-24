import { useLayoutEffect, useState } from "preact/hooks";
import { StructuredFieldsEditor } from "../Capabilities";
import { RichNoteEditor, flushRichNote } from "../RichNoteEditor";
import { fmt, t, useLocale } from "../i18n";
import { type Item, Markdown } from "./components";

export function Editor({
  item,
  onCancel,
  onSave,
  onDraft,
  busy,
  draftStatus = "idle",
}: {
  item: Item;
  onCancel: () => void;
  onSave: (item: Item) => void;
  onDraft: (item: Item) => void;
  busy: boolean;
  draftStatus?: "idle" | "saving" | "saved" | "failed";
}) {
  useLocale();
  const [draft, setDraft] = useState<Item>(item);
  const [preview, setPreview] = useState(false);
  const [flushing, setFlushing] = useState(false);
  const [editorError, setEditorError] = useState("");
  useLayoutEffect(() => {
    if (draft !== item) onDraft(draft);
  }, [draft]);
  const update = (key: string, value: any) =>
    setDraft({ ...draft, [key]: value });
  function field(key: string, label: string, secret = false) {
    return (
      <label>
        {t(label)}
        <input
          type={secret ? "password" : "text"}
          value={draft[key] ?? ""}
          onInput={(e) => update(key, e.currentTarget.value)}
          autoComplete="off"
        />
      </label>
    );
  }
  return (
    <form
      class="editor"
      onSubmit={async (e) => {
        e.preventDefault();
        if (flushing || busy) return;
        setFlushing(true);
        setEditorError("");
        try {
          const rich = await flushRichNote(draft.id);
          const next: Item = {
            ...draft,
            ...(rich
              ? {
                  note: rich.note,
                  noteFormat: rich.noteFormat,
                  noteDocument: rich.noteDocument,
                  ...(rich.noteOriginal ? { noteOriginal: rich.noteOriginal } : {}),
                }
              : {}),
          };
          if (
            item.type === "password" &&
            item.password &&
            item.password !== draft.password
          )
            next.passwordHistory = [
              ...(item.passwordHistory ?? []),
              { password: item.password, changedAt: new Date().toISOString() },
            ];
          onDraft(next);
          onSave(next);
        } catch {
          setEditorError(t("编辑器仍在处理，请稍后重试保存。"));
        } finally {
          setFlushing(false);
        }
      }}
    >
      <header class="detail-toolbar">
        <span>{item.title ? t("编辑资料") : t("新建资料")}</span>
        <div class="actions">
          <button type="button" onClick={onCancel}>
            {t("取消")}
          </button>
          <button class="primary" disabled={busy || flushing}>
            {t("保存")}
          </button>
        </div>
      </header>
      <div class="editor-fields" inert={busy || flushing}>
        {editorError && <p role="alert">{editorError}</p>}
        <input
          class="title-input"
          aria-label={t("标题")}
          required
          placeholder={t("标题")}
          value={draft.title}
          onInput={(e) => update("title", e.currentTarget.value)}
        />
        {item.type === "password" && (
          <>
            {field("username", t("账号"))}
            {field("password", t("密码"), true)}
            {field("url", t("网站"))}
          </>
        )}
        {item.type === "totp" && (
          <>
            {field("username", t("账号"))}
            {field("secret", t("密钥"), true)}
            {field("url", t("网站"))}
            <label>
              {t("刷新间隔（秒）")}
              <input
                type="number"
                min="1"
                max="86400"
                value={draft.period ?? 30}
                onInput={(e) => update("period", Number(e.currentTarget.value))}
              />
            </label>
          </>
        )}
        {item.type === "crypto" && (
          <>
            {field("network", t("网络"))}
            {field("address", t("地址"))}
            {field("privateKey", t("私钥"), true)}
            {field("mnemonic", t("助记词"), true)}
          </>
        )}
        <StructuredFieldsEditor item={draft} onChange={setDraft} />
        {field("category", t("分类"))}
        <label>
          {t("标签（逗号分隔）")}
          <input
            value={(draft.tags ?? []).join(", ")}
            onInput={(e) =>
              update(
                "tags",
                e.currentTarget.value
                  .split(/[,，]/)
                  .map((v) => v.trim())
                  .filter(Boolean),
              )
            }
          />
        </label>
        <div class="editor-options">
          <span>Markdown</span>
          <button
            type="button"
            aria-pressed={preview}
            onClick={() => setPreview(!preview)}
          >
            {preview ? t("编辑") : t("预览")}
          </button>
          <label>
            <input
              type="checkbox"
              checked={!!draft.isPinned}
              onChange={(e) => update("isPinned", e.currentTarget.checked)}
            />
            {t("置顶")}
          </label>
        </div>
        {draft.type === "secureNote" ? (
          <RichNoteEditor
            key={draft.id}
            item={item}
            editable
            onChange={(value) =>
              setDraft((previous) => ({
                ...previous,
                noteFormat: value.noteFormat,
                noteDocument: value.noteDocument,
                ...(value.noteOriginal ? { noteOriginal: value.noteOriginal } : {}),
                note: value.note,
              }))
            }
          />
        ) : preview ? (
          <Markdown text={draft.note ?? ""} />
        ) : (
          <textarea
            class="note-editor"
            aria-label={t("笔记正文")}
            placeholder={t("开始写下重要的事…")}
            value={draft.note ?? ""}
            onInput={(e) => update("note", e.currentTarget.value)}
          />
        )}
      </div>
      <footer class="detail-status editor-status" role="status">
        <span>{draft === item ? t("尚未修改") : draftStatus === "saved" ? t("草稿已加密保存") : draftStatus === "failed" ? t("草稿未能保存") : t("正在加密保存草稿…")}</span>
        <span>{fmt(t("{count} 字"), { count: [...(draft.note ?? "")].length })}</span>
      </footer>
    </form>
  );
}
