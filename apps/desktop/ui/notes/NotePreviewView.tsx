// Clean, auto-height reading view for Notes (`预览` mode), with polished typography,
// clickable [[wikilinks]], pv-asset:// preview triggers, and code-block copy buttons.
import { View } from "nsh";
import { TextView } from "nsh/base";
import { NoteMarkdown } from "passwordvault/native";
import { openSite } from "../kit";
import { createItem, items, reveal, toast, type Item } from "../store";
import { c, fs, MONO } from "../theme";
import { listNoteAssets } from "../api/noteAssets";
import { openAssetPreviewSheet } from "./AssetPreviewSheet";
import { documentFor, type Node } from "./model";
import { project } from "./projection";

function resolveDoc(item: Item): Node {
  if (item.noteFormat === "rich-v1" && item.noteDocument) return item.noteDocument;
  try {
    const parsed = JSON.parse(NoteMarkdown.fromMarkdown(String(item.note ?? "")));
    if (parsed?.noteDocument) return parsed.noteDocument as Node;
  } catch {}
  return documentFor({ id: item.id, note: item.note, noteFormat: "plain" });
}

export function NotePreviewView(props: { item: Item }) {
  const onLinkPress = ({ url }: { url: string }) => {
    if (!url) return;
    if (url.startsWith("pv-wiki://")) {
      const title = decodeURIComponent(url.slice("pv-wiki://".length)).trim();
      if (!title) return;
      const target = items().find(
        (n) => n.type === "secureNote" && !n.isDeleted && n.title?.trim().toLowerCase() === title.toLowerCase(),
      );
      if (target) {
        reveal(target);
      } else {
        void createItem("secureNote", { title, category: props.item.category ?? "" }).then(() => {
          toast(`已创建并打开关联笔记「${title}」`);
        });
      }
      return;
    }
    if (url.startsWith("pv-asset://")) {
      const aid = url.slice("pv-asset://".length).trim();
      if (!aid) return;
      void listNoteAssets(props.item.id).then((list) => {
        const asset = list.find((a) => a.id === aid);
        if (asset) openAssetPreviewSheet(props.item.id, asset);
        else toast("未找到该加密资产附件");
      });
      return;
    }
    if (/^(https?:\/\/|mailto:)/i.test(url)) {
      openSite(url);
    }
  };

  return (
    <View testID="note-preview-view" style={{ paddingTop: 6, paddingBottom: 14 }}>
      <TextView
        document={project(resolveDoc(props.item))}
        selectable
        links="report"
        codeBlockActions={[{ id: "copy", label: "复制代码" }]}
        onLinkPress={onLinkPress}
        styles={{
          root: { fontSize: fs(14.5), lineHeight: fs(26), color: c().ink },
          paragraph: { marginTop: 0, marginBottom: 12, lineHeight: fs(26), color: c().ink },
          heading1: { fontSize: fs(21), lineHeight: fs(30), fontWeight: "700", marginTop: 10, marginBottom: 12, color: c().ink },
          heading2: { fontSize: fs(17.5), lineHeight: fs(26), fontWeight: "600", marginTop: 24, marginBottom: 10, color: c().ink },
          heading3: { fontSize: fs(15.5), lineHeight: fs(24), fontWeight: "600", marginTop: 18, marginBottom: 8, color: c().ink },
          blockquote: {
            borderLeftWidth: 3,
            borderLeftColor: c().blueLine,
            backgroundColor: c().soft2,
            borderRadius: 6,
            paddingLeft: 14,
            paddingRight: 12,
            paddingVertical: 8,
            marginTop: 4,
            marginBottom: 14,
            color: c().ink2,
          },
          list: { marginTop: 2, marginBottom: 14, gap: 6 },
          listItem: { lineHeight: fs(25) },
          listMarker: { color: c().muted },
          codeBlock: {
            backgroundColor: c().soft2,
            borderWidth: 1,
            borderColor: c().line,
            borderRadius: 8,
            padding: 12,
            marginTop: 4,
            marginBottom: 14,
          },
          codeBlockCode: { fontFamily: MONO, fontSize: fs(13), lineHeight: fs(21) },
          code: { fontFamily: MONO, fontSize: fs(13), backgroundColor: c().soft2, color: c().blue, paddingHorizontal: 4, borderRadius: 4 },
          link: { color: c().blue },
          table: { marginTop: 6, marginBottom: 14, borderWidth: 1, borderColor: c().line, borderRadius: 8 },
          tableHeaderCell: { backgroundColor: c().soft2, padding: 8, fontSize: fs(12.5), fontWeight: "600", color: c().muted },
          tableCell: { padding: 8, fontSize: fs(13), borderTopWidth: 1, borderTopColor: c().line },
          rule: { borderTopWidth: 1, borderTopColor: c().line, marginVertical: 18 },
        }}
      />
    </View>
  );
}
