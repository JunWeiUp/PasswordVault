// Small task sheets shared by several screens.
import { signal, View } from "nsh";
import { Btn, confirm, copySecret, openSheet, SheetFooter, SheetTitle, T, TextBox, Toggle } from "./kit";
import { desktopCapabilities } from "./native";
import { setCategoryAiWritable } from "./ai";
import { catMatches } from "./notes/knowledge";
import {
  addCategory, deleteForever, emptyTrash, items, moveToTrash, removeCategory, renameCategory, saveMilestone, type Item,
} from "./store";
import { c } from "./theme";

export function askCategory(prefix?: unknown) {
  const initial = typeof prefix === "string" && prefix.trim() ? `${prefix.trim().replace(/^\/+|\/+$/g, "")}/` : "";
  const name = signal(initial);
  const aiWritable = signal(false);
  openSheet({
    width: 440,
    render: (close) => {
      const submit = () => {
        const v = name().trim().replace(/^\/+|\/+$/g, "");
        if (!v) return;
        const allowAi = aiWritable();
        close();
        void (async () => {
          await addCategory(v);
          if (allowAi && desktopCapabilities.ai) await setCategoryAiWritable(v, true);
        })();
      };
      return (
        <View style={{ gap: 10 }}>
          <SheetTitle title={initial ? `在「${initial.slice(0, -1)}」下新建子目录` : "新增笔记目录"} text="支持用 / 创建多级目录（如 资产/持仓、健康/体检），保存在加密密码库中。" />
          <TextBox testID="category-add-input" value={name()} onChange={(v) => name.set(v)} placeholder="例如：资产/持仓 或 健康/体检" autoFocus onSubmit={submit} />
          <If when={desktopCapabilities.ai}>
            <Toggle
              title="允许已配对 AI 免弹窗自动保存"
              note="仅开放此目录及子目录下的笔记；AI 每次写入都必须带摘要并自动保留版本历史。"
              checked={aiWritable()}
              onChange={(v) => aiWritable.set(v)}
            />
          </If>
          <SheetFooter>
            <Btn label="取消" onPress={close} />
            <Btn testID="category-add-confirm" label="添加" kind="primary" disabled={!name().trim().replace(/^\/+|\/+$/g, "")} onPress={submit} />
          </SheetFooter>
        </View>
      );
    },
  });
}

export function askSaveMilestone(item: Item, onSaved?: () => void) {
  const summary = signal("");
  const saving = signal(false);
  openSheet({
    width: 440,
    render: (close) => {
      const submit = () => {
        const v = summary().trim();
        if (!v || saving()) return;
        saving.set(true);
        void saveMilestone(item.id, v).then((ok) => {
          saving.set(false);
          if (ok) {
            close();
            onSaved?.();
          }
        });
      };
      return (
        <View style={{ gap: 10 }}>
          <SheetTitle title="保存里程碑版本" text={`为「${item.title || "未命名笔记"}」打一个持久快照，清理旧版本时默认保留。`} />
          <TextBox testID="milestone-summary" label="里程碑说明" value={summary()} onChange={(v) => summary.set(v)} placeholder="例如：2026 Q3 持仓结算、体检复查归档…" autoFocus onSubmit={submit} />
          <SheetFooter>
            <Btn label="取消" disabled={saving()} onPress={close} />
            <Btn testID="milestone-confirm" label={saving() ? "正在保存…" : "保存里程碑"} kind="primary" disabled={saving() || !summary().trim()} onPress={submit} />
          </SheetFooter>
        </View>
      );
    },
  });
}

export function askRenameCategory(current: string) {
  const name = signal(current);
  openSheet({
    width: 420,
    render: (close) => {
      const submit = () => {
        const v = name().trim();
        if (!v || v === current) return;
        close();
        void renameCategory(current, v);
      };
      return (
        <View style={{ gap: 10 }}>
          <SheetTitle title={`重命名分类「${current}」`} text="分类中的笔记（包括回收站中的）会一并移到新名称下。" />
          <TextBox testID="category-rename" value={name()} onChange={(v) => name.set(v)} autoFocus onSubmit={submit} />
          <SheetFooter>
            <Btn label="取消" onPress={close} />
            <Btn testID="category-rename-confirm" label="重命名" kind="primary" disabled={!name().trim() || name().trim() === current} onPress={submit} />
          </SheetFooter>
        </View>
      );
    },
  });
}

export function askRemoveCategory(name: string) {
  const n = items().filter((i) => i.type === "secureNote" && catMatches(i.category, name)).length;
  confirm({
    title: `删除分类「${name}」？`,
    text: `其中的 ${n} 篇笔记（含子目录）不会被删除，会保留在「全部笔记」中并变为未分类（回收站中的笔记仍留在回收站）。`,
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
