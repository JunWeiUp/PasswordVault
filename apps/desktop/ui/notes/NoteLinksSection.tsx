// Wikilinks (outgoing) and backlinks (incoming) panel for secure notes.
import { cleanup, effect, signal, View } from "nsh";
import { Icon } from "../icons";
import { Row, T } from "../kit";
import { createItem, items, reveal, toast, type Item } from "../store";
import { c } from "../theme";
import { catLeaf, extractWikilinks, findNoteBacklinks, noteToMarkdown } from "./knowledge";

export function NoteLinksSection(props: { item: Item }) {
  const item = () => props.item;
  const outgoing = signal<string[]>([]);
  const incoming = signal<ReturnType<typeof findNoteBacklinks>>([]);
  let lastId = "";
  let timer: ReturnType<typeof setTimeout> | null = null;
  let alive = true;
  cleanup(() => {
    alive = false;
    if (timer !== null) { clearTimeout(timer); timer = null; }
  });

  // Compute links immediately on note switch; debounce 450ms while typing so keystrokes
  // never scan every note in the vault synchronously.
  effect(() => {
    const cur = item();
    const list = items();
    const id = cur.id;
    const revKey = `${id}:${cur.title ?? ""}:${cur.slug ?? ""}:${cur.updatedAt ?? ""}:${list.length}`;
    void revKey;
    const computeNow = () => {
      if (!alive) return;
      outgoing.set(extractWikilinks(noteToMarkdown(cur)));
      incoming.set(findNoteBacklinks(cur, list));
    };
    if (timer !== null) { clearTimeout(timer); timer = null; }
    if (id !== lastId) {
      lastId = id;
      computeNow();
    } else {
      timer = setTimeout(() => { timer = null; computeNow(); }, 450);
    }
  });

  const findTarget = (titleOrSlug: string) =>
    items().find(
      (n) =>
        n.type === "secureNote" &&
        !n.isDeleted &&
        n.id !== item().id &&
        (n.title === titleOrSlug || n.slug === titleOrSlug),
    );

  const openOrCreateLink = (title: string) => {
    const existing = findTarget(title);
    if (existing) {
      reveal(existing);
      return;
    }
    if (item().isDeleted) return;
    void createItem("secureNote", { title, category: item().category ?? "" }).then(() => {
      toast(`已新建双链笔记「${title}」`);
    });
  };

  return (
    <If when={outgoing().length > 0 || incoming().length > 0}>
      <View
        testID="note-links-section"
        style={{
          marginTop: 22,
          paddingTop: 16,
          borderTopWidth: 1,
          borderTopColor: c().line,
          gap: 14,
        }}
      >
        <If when={outgoing().length > 0}>
          <View style={{ gap: 8 }}>
            <Row gap={6}>
              <Icon name="link" size={13} tint={c().muted} />
              <T size={12} weight="600" color={c().ink2}>双链引用（{outgoing().length}）</T>
            </Row>
            <Row gap={6} wrap>
              {outgoing().map((title) => {
                const target = () => findTarget(title);
                return (
                  <View
                    role="button"
                    accessibilityLabel={`打开双链 ${title}`}
                    onPress={() => openOrCreateLink(title)}
                    style={{
                      flexDirection: "row",
                      alignItems: "center",
                      gap: 5,
                      paddingHorizontal: 9,
                      paddingVertical: 4,
                      borderRadius: 6,
                      borderWidth: 1,
                      borderColor: target() ? c().blueLine : c().line,
                      backgroundColor: target() ? c().blueSoft : c().soft2,
                      cursor: "pointer",
                    }}
                    hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blue }}
                  >
                    <T size={12} color={target() ? c().blue : c().muted}>[[{title}]]</T>
                    <If when={!target()}>
                      <T size={10.5} color={c().faint}>新建</T>
                    </If>
                  </View>
                );
              })}
            </Row>
          </View>
        </If>

        <If when={incoming().length > 0}>
          <View style={{ gap: 8 }}>
            <Row gap={6}>
              <Icon name="link" size={13} tint={c().blue} />
              <T size={12} weight="600" color={c().ink2}>反向链接（{incoming().length}）</T>
            </Row>
            <View style={{ gap: 6 }}>
              {incoming().map((ref) => (
                <View
                  role="button"
                  testID={`backlink-${ref.item.id}`}
                  accessibilityLabel={`跳转到 ${ref.item.title}`}
                  onPress={() => reveal(ref.item)}
                  style={{
                    paddingHorizontal: 11,
                    paddingVertical: 8,
                    borderRadius: 8,
                    borderWidth: 1,
                    borderColor: c().line,
                    backgroundColor: c().soft2,
                    gap: 3,
                    cursor: "pointer",
                  }}
                  hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blueLine }}
                >
                  <Row gap={6}>
                    <Icon name="note" size={12} tint={c().blue} />
                    <T size={12.5} weight="600" color={c().blue} style={{ flex: 1 }} lines={1}>
                      {ref.item.title || "未命名笔记"}
                    </T>
                    <T size={11} color={c().faint}>{catLeaf(ref.item.category)}</T>
                  </Row>
                  <If when={ref.snippet}>
                    <T size={11.5} color={c().muted} lines={1}>{ref.snippet}</T>
                  </If>
                </View>
              ))}
            </View>
          </View>
        </If>
      </View>
    </If>
  );
}
