// "Save as Markdown / HTML" for one note. The exported file is NOT encrypted, so the
// user confirms first; nothing is written without a save panel choice.
import { Files, NoteMarkdown } from "passwordvault/native";
import { confirm } from "../kit";
import { flush, items, toast, type Item } from "../store";

export type NoteExportFormat = "markdown" | "html";

/** The note body as Markdown: rich notes are serialized, legacy notes are already Markdown. */
export function noteMarkdown(item: Item): string {
  if (item.noteFormat === "rich-v1" && item.noteDocument) {
    return JSON.parse(NoteMarkdown.toMarkdown(JSON.stringify(item.noteDocument))).markdown as string;
  }
  return String(item.note ?? "");
}

const safeName = (title: string) =>
  (title.trim() || "未命名笔记").replace(/[\\/:*?"<>|\u0000-\u001f]/g, "-").slice(0, 80);

export function askExportNote(item: Item, format: NoteExportFormat) {
  const ext = format === "html" ? "html" : "md";
  confirm({
    title: `将「${item.title || "未命名"}」另存为 ${format === "html" ? "HTML" : "Markdown"}？`,
    text: "导出的文件不加密，任何能访问该文件的人都能读取。附件和图片不会一起导出。",
    ok: "选择保存位置…",
    onConfirm: () => void exportNote(item.id, format, ext),
  });
}

async function exportNote(id: string, format: NoteExportFormat, ext: string) {
  try {
    if (!(await flush())) return;
    const item = items().find((i) => i.id === id);
    if (!item) return;
    const path = await Files.pickSave("另存笔记", `${safeName(item.title)}.${ext}`, [ext]);
    if (!path) return;
    const markdown = noteMarkdown(item);
    const contents = format === "html" ? NoteMarkdown.toHtml(markdown, item.title || "未命名笔记") : markdown;
    await Files.saveNoteExport(path, contents);
    toast(`已另存为 ${path.split(/[\\/]/).pop()}`);
  } catch (e) {
    const message = String(e);
    toast(message.includes("AlreadyExists") ? "文件已存在，请换一个文件名" : "另存未完成，请重试");
  }
}
