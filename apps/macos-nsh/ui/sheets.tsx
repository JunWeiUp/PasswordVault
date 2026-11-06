// Small task sheets shared by several screens.
import { signal, View } from "nsh";
import { Btn, confirm, copySecret, openSheet, SheetFooter, SheetTitle, T, TextBox } from "./kit";
import {
  addCategory, deleteForever, emptyTrash, items, moveToTrash, removeCategory, type Item,
} from "./store";
import { c } from "./theme";

export function askCategory() {
  const name = signal("");
  openSheet({
    width: 420,
    render: (close) => {
      const submit = () => {
        const v = name().trim();
        if (!v) return;
        close();
        void addCategory(v);
      };
      return (
        <View style={{ gap: 10 }}>
          <SheetTitle title="新增笔记分类" text="分类保存在加密密码库中，空分类也会保留。" />
          <TextBox value={name()} onChange={(v) => name.set(v)} placeholder="例如：健康" autoFocus onSubmit={submit} />
          <SheetFooter>
            <Btn label="取消" onPress={close} />
            <Btn label="添加" kind="primary" disabled={!name().trim()} onPress={submit} />
          </SheetFooter>
        </View>
      );
    },
  });
}

export function askRemoveCategory(name: string) {
  const n = items().filter((i) => i.type === "secureNote" && i.category === name).length;
  confirm({
    title: `删除分类「${name}」？`,
    text: `其中的 ${n} 篇笔记不会被删除，会保留在「全部笔记」中并变为未分类（回收站中的笔记仍留在回收站）。`,
    ok: "删除分类",
    danger: true,
    onConfirm: () => void removeCategory(name),
  });
}

export function askTrash(item: Item) {
  confirm({
    title: `将「${item.title || "未命名"}」移到回收站？`,
    text: "可以在回收站中恢复。",
    ok: "移到回收站",
    danger: true,
    onConfirm: () => void moveToTrash(item),
  });
}

export function askDeleteForever(item: Item) {
  confirm({
    title: `永久删除「${item.title || "未命名"}」？`,
    text: "此操作无法撤销，本机的版本历史也会一并删除。已有的备份不受影响。",
    ok: "永久删除",
    danger: true,
    onConfirm: () => void deleteForever(item),
  });
}

export function askEmptyTrash() {
  const n = items().filter((i) => i.isDeleted).length;
  confirm({
    title: `清空回收站中的 ${n} 个项目？`,
    text: "此操作无法撤销。已有的备份不受影响。",
    ok: "清空回收站",
    danger: true,
    onConfirm: () => void emptyTrash(),
  });
}

export function showPasswordHistory(item: Item) {
  const list: { password: string; changedAt: string }[] = item.passwordHistory ?? [];
  openSheet({
    render: (close) => (
      <View style={{ gap: 8 }}>
        <SheetTitle title={`密码历史 · ${item.title}`} text="修改密码时自动保留旧密码，便于网站回滚时找回。" />
        {list.map((h) => (
          <HistoryRow value={h.password} at={h.changedAt} />
        ))}
        <SheetFooter><Btn label="完成" kind="primary" onPress={close} /></SheetFooter>
      </View>
    ),
  });
}

function HistoryRow(props: { value: string; at: string }) {
  const shown = signal(false);
  return (
    <View style={{ flexDirection: "row", alignItems: "center", gap: 10, paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
      <T mono size={12.5} style={{ flex: 1 }} selectable={shown()}>{shown() ? props.value : "••••••••••••"}</T>
      <T size={11} color={c().muted}>{props.at ? props.at.slice(0, 10) : ""}</T>
      <Btn kind="ghost" label={shown() ? "隐藏" : "显示"} onPress={() => shown.update((s) => !s)} />
      <Btn kind="ghost" icon="copy" label="复制" onPress={() => copySecret(props.value, "旧密码")} />
    </View>
  );
}
