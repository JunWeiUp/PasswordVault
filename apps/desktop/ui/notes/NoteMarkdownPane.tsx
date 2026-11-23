// Canonical Markdown source editor pane for secure notes (matches Agent MCP format).
import { effect, signal, View } from "nsh";
import { Editor } from "nsh/base";
import { Icon } from "../icons";
import { Btn, copySecret, Row, T } from "../kit";
import { noteMarkdownNative } from "../api/nativeBridge";
import { noteLineNumbers, setNoteLineNumbers } from "../preferences";
import { edit, toast, type Item } from "../store";
import { c, fs, MONO } from "../theme";
import { noteToMarkdown } from "./knowledge";

export function NoteMarkdownPane(props: { item: Item; editable: boolean }) {
  const item = () => props.item;
  const draft = signal(noteToMarkdown(props.item));
  const dirty = signal(false);
  const err = signal("");
  let trackedKey = `${props.item.id}:${props.item.updatedAt ?? ""}`;

  effect(() => {
    const cur = item();
    const key = `${cur.id}:${cur.updatedAt ?? ""}`;
    if (key !== trackedKey && !dirty()) {
      trackedKey = key;
      draft.set(noteToMarkdown(cur));
      err.set("");
    }
  });

  const applyMarkdown = () => {
    if (!props.editable || !dirty()) return;
    try {
      const parser = noteMarkdownNative.fromMarkdownPreserving;
      const raw =
        typeof parser === "function" && item().noteDocument
          ? parser(draft(), JSON.stringify(item().noteDocument))
          : noteMarkdownNative.fromMarkdown(draft());
      const parsed = JSON.parse(raw);
      edit(item().id, (d) => {
        if (d.noteFormat !== "rich-v1" && !d.noteOriginal) {
          d.noteOriginal = { format: d.noteFormat ?? "plain", source: String(d.note ?? "") };
        }
        d.noteFormat = "rich-v1";
        d.noteDocument = parsed.noteDocument;
        d.note = parsed.text;
        d.lastActor = "手动编辑 · 我";
      });
      dirty.set(false);
      err.set("");
      toast("已同步 Markdown 修改");
    } catch (e) {
      err.set(`Markdown 解析失败：${String(e)}`);
    }
  };

  return (
    <View testID="note-markdown-pane" style={{ gap: 10 }}>
      <Row style={{ justifyContent: "space-between", paddingBottom: 6, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
        <T size={11.5} color={c().muted}>规范 Markdown · 与 Agent MCP 读写格式一致</T>
        <Row gap={6}>
          <View
            testID="md-line-numbers-toggle"
            role="button"
            accessibilityLabel={noteLineNumbers() ? "隐藏行号" : "显示行号"}
            tooltip={noteLineNumbers() ? "隐藏行号" : "显示行号"}
            accessibilityState={{ selected: noteLineNumbers() }}
            onPress={() => setNoteLineNumbers(!noteLineNumbers())}
            style={{
              flexDirection: "row",
              alignItems: "center",
              gap: 4,
              height: 26,
              paddingHorizontal: 8,
              borderRadius: 6,
              borderWidth: 1,
              borderColor: noteLineNumbers() ? c().blueLine : c().line,
              backgroundColor: noteLineNumbers() ? c().blueSoft : c().surface,
              cursor: "pointer",
            }}
            hoverStyle={{ backgroundColor: noteLineNumbers() ? c().blueSoft : c().field }}
          >
            <Icon name="lineNumbers" size={12} tint={noteLineNumbers() ? c().blue : c().ink2} />
            <T size={11.5} weight="500" color={noteLineNumbers() ? c().blue : c().ink2}>行号</T>
          </View>
          <Btn label="复制 Markdown" icon="copy" onPress={() => void copySecret(draft(), "Markdown")} />
          <If when={props.editable && dirty()}>
            <Btn testID="md-apply-btn" label="应用修改" icon="check" kind="primary" onPress={applyMarkdown} />
          </If>
        </Row>
      </Row>
      <If when={err()}>
        <T size={12} color={c().red}>{err()}</T>
      </If>
      <Editor
        testID="note-markdown-input"
        value={draft()}
        language="markdown"
        readOnly={!props.editable}
        placeholder="（空白笔记）"
        lineNumbers={noteLineNumbers()}
        folding={false}
        softWrap
        activeLine={props.editable}
        indentGuides={false}
        scrollBeyondLastLine={false}
        fontFamily={MONO}
        fontSize={fs(12.5)}
        lineHeight={fs(21)}
        accessibilityLabel="Markdown 源码"
        onChange={({ value }) => {
          if (!props.editable) return;
          draft.set(value);
          dirty.set(true);
        }}
        onBlur={applyMarkdown}
        style={{
          height: 440,
          borderRadius: 8,
          borderWidth: 1,
          borderColor: c().line,
          backgroundColor: c().soft2,
        }}
        styles={{
          gutter: {
            backgroundColor: c().soft2,
            borderRightWidth: 1,
            borderRightColor: c().line,
            paddingLeft: 8,
            paddingRight: 10,
          },
          lineNumber: {
            color: c().faint,
            fontFamily: MONO,
            fontSize: fs(11.5),
          },
          activeLineNumber: {
            color: c().ink2,
            fontWeight: "600",
          },
          activeLine: {
            backgroundColor: c().soft,
          },
          content: {
            color: c().ink,
            paddingHorizontal: 14,
            paddingVertical: 10,
          },
        }}
      />
    </View>
  );
}
