import { runnableScript, TerminalPreference } from "./ScriptRun";
import { signal, Scroll, View } from "nsh";
import { Input } from "nsh/base";
import { Menu } from "nsh/desktop";
import { Btn, IconBtn, Row, T, TextBox, Toggle, copySecret, confirm } from "../kit";
import { c, MONO } from "../theme";
import { commandTitle, documentKind, type DeviceCommand } from "./model";

export function DocumentLibrary(props: {
  commands: DeviceCommand[];
  editable: boolean;
  canManage?: boolean;
  busy: boolean;
  selectedId?: string;
  onSelect?: (id: string) => void;
  showHeaderActions?: boolean;
  onEdit?: () => void;
  onRun?: (row: DeviceCommand) => void;
  onImport: () => void;
  onChange: (rows: DeviceCommand[]) => void;
  onDelete?: (row: DeviceCommand, remaining: DeviceCommand[]) => void;
}) {
  const localSelected = signal(""), revealed = signal(true), query = signal(""), width = signal(800);
  const selected = () => props.selectedId ?? localSelected();
  const selectDoc = (id: string) => { localSelected.set(id); props.onSelect?.(id); };
  const current = () => props.commands.find(row => row.id === selected()) ?? props.commands[0];
  const manageable = () => props.canManage ?? props.editable;
  const matches = (row: DeviceCommand) => {
    const q = query().trim().toLowerCase();
    return !q || commandTitle(row).toLowerCase().includes(q) || row.title.toLowerCase().includes(q);
  };
  const update = (patch: Partial<DeviceCommand>) => {
    if (props.editable && current()) props.onChange(props.commands.map(row => row.id === current()?.id ? { ...row, ...patch } : row));
  };
  const add = () => {
    if (!manageable()) return;
    const row: DeviceCommand = { id: crypto.randomUUID(), title: "未命名.txt", label: "", text: "", secret: true };
    props.onChange([...props.commands, row]); selectDoc(row.id); revealed.set(true); if (!props.editable) props.onEdit?.();
  };
  const removeRow = (row: DeviceCommand) => {
    if (!manageable()) return;
    const title = commandTitle(row);
    confirm({
      title: `删除资料「${title}」？`,
      text: "仅从当前设备的资料目录中移除这一条记录，原始本地文件不受影响。如已启用版本历史，旧版本中仍可找回。",
      ok: "删除此资料",
      danger: true,
      onConfirm: () => {
        if (!manageable()) return;
        const idx = props.commands.findIndex(r => r.id === row.id);
        const remaining = props.commands.filter(r => r.id !== row.id);
        if (props.onDelete) props.onDelete(row, remaining);
        else props.onChange(remaining);
        if (current()?.id === row.id) {
          const fallback = remaining[Math.min(Math.max(0, idx), Math.max(0, remaining.length - 1))]?.id ?? "";
          selectDoc(fallback);
        }
      },
    });
  };
  const rowContextMenu = (row: DeviceCommand, pos?: { x: number; y: number }) => {
    const items: any[] = [
      { label: "查看资料", onSelect: () => { selectDoc(row.id); revealed.set(true); } },
      { label: "复制全文", disabled: !row.text, onSelect: () => void copySecret(row.text, "资料全文") },
    ];
    if (manageable()) {
      items.push({ separator: true });
      items.push({ label: `删除「${commandTitle(row)}」…`, onSelect: () => removeRow(row) });
    }
    void Menu.popup(items, pos);
  };
  return <View onLayout={e => width.set(e.bounds.size.width)} style={{ gap: 18 }}>
    <If when={props.showHeaderActions !== false}>
      <Row wrap style={{ justifyContent: "space-between" }}>
        <T color={c().muted}>{props.commands.length} 份资料 · 加密保存</T>
        <Row gap={8}><Btn label="新建资料" disabled={!manageable()} onPress={add} /><Btn label="导入文件…" kind="primary" disabled={!manageable() || props.busy} onPress={props.onImport} /></Row>
      </Row>
    </If>
    <View style={{ flexDirection: width() < 600 ? "column" : "row", gap: 22, alignItems: "stretch" }}>
      <View style={{ width: width() < 600 ? undefined : 220, gap: 12, flexShrink: 0 }}>
        <Row style={{ justifyContent: "space-between" }}>
          <T weight="600">资料目录</T>
          <T size={11} color={c().muted}>{props.commands.length} 个文件</T>
        </Row>
        <TextBox label="搜索资料" placeholder="搜索标题或文件名…" value={query()} onChange={v => query.set(v)} />
        <Scroll style={{ maxHeight: width() < 600 ? 180 : 460 }}><View style={{ gap: 4 }}>
          {props.commands.filter(matches).map(row => {
            const active = () => current()?.id === row.id;
            const title = commandTitle(row);
            return <View
              testID={`doc-row-${row.id}`}
              onContextMenu={(e: any) => rowContextMenu(row, e?.pagePosition)}
              style={{
                flexDirection: "row",
                alignItems: "flex-start",
                gap: 4,
                padding: 4,
                borderRadius: 7,
                borderWidth: 1,
                borderColor: active() ? c().blueLine : "transparent",
                backgroundColor: active() ? c().blueSoft : "transparent",
              }}
              hoverStyle={{ backgroundColor: active() ? c().blueSoft : c().soft }}
            >
              <View
                role="button"
                accessibilityLabel={`打开 ${title}`}
                onPress={() => { selectDoc(row.id); revealed.set(true); }}
                style={{ flex: 1, minWidth: 0, paddingHorizontal: 8, paddingVertical: 7, gap: 4, cursor: "pointer" }}
              >
                <T weight="600" size={12} color={active() ? c().blue : c().ink} lines={2}>{title}</T>
                <T size={10.5} color={c().muted} lines={1}>{row.label?.trim() && row.title ? `${row.title} · ` : ""}{documentKind(row.title)} · {row.text.split("\n").length} 行</T>
              </View>
              <If when={manageable()}>
                <View style={{ paddingTop: 4, paddingRight: 2 }}>
                  <IconBtn
                    testID={`doc-row-delete-${row.id}`}
                    icon="trash"
                    label={`删除 ${title}`}
                    size={13}
                    tint={c().muted}
                    onPress={() => removeRow(row)}
                  />
                </View>
              </If>
            </View>;
          })}
          <If when={query().trim() && !props.commands.some(matches)}><T color={c().muted}>没有匹配的文件</T></If>
        </View></Scroll>
        <T size={11} color={c().muted}>脚本、命令、配置与文本。每条资料可点击右侧删除图标或右键单独删除；点击运行将在首选终端执行。</T>
      </View>
      <View style={{ flex: 1, minWidth: 0, gap: 12 }}>
        <If when={current()} else={<View style={{ paddingVertical: 40, gap: 12 }}><T size={18} weight="600">还没有资料</T><T color={c().muted}>导入 Python、Shell 或配置文件，也可以新建文本。</T></View>}>
          <T size={19} weight="600" selectable>{commandTitle(current())}</T>
          <T size={11} color={c().muted}>{current()?.label?.trim() && current()?.title ? `${current()?.title} · ` : ""}{documentKind(current()?.title ?? "")} · {current()?.secret ? "敏感资料" : "文本资料"}</T>
          <If when={props.editable}>
            <View style={{ gap: 6 }}>
              <T size={11.5} color={c().muted}>标题</T>
              <TextBox label="资料标题" placeholder="可选，设置后默认显示为标题内容" value={current()?.label ?? ""} onChange={label => update({ label })} />
            </View>
            <View style={{ gap: 6 }}>
              <T size={11.5} color={c().muted}>完整文件名（含扩展名）</T>
              <TextBox label="完整文件名（含扩展名）" placeholder="例如 deploy.sh 或 config.json" value={current()?.title ?? ""} onChange={title => update({ title })} />
            </View>
          </If>
          <Row wrap style={{ backgroundColor: c().soft, padding: 10, gap: 6, borderRadius: 8 }}>
            <T size={11} color={c().muted} style={{ flex: 1 }}>{props.editable ? "编辑中 · 自动保存" : "只读预览"}</T>
            <Btn label={revealed() ? "收起内容" : "显示内容"} onPress={() => revealed.set(!revealed())} />
            <If when={props.onEdit && manageable()}><Btn label={props.editable ? "完成编辑" : "编辑资料"} onPress={props.onEdit} /></If>
            <If when={props.onRun && manageable() && runnableScript(current()?.title ?? "")}><TerminalPreference /><Btn label="点击运行" disabled={!current()?.text || props.busy} onPress={() => { const row = current(); if (row) props.onRun?.(row); }} /></If>
            <Btn label="复制全文" kind="primary" disabled={!current()?.text} onPress={() => void copySecret(current()?.text ?? "", "资料全文")} />
            <If when={manageable() && current()}>
              <Btn testID="doc-toolbar-delete" label="删除" icon="trash" kind="danger" onPress={() => { const row = current(); if (row) removeRow(row); }} />
            </If>
          </Row>
          <If when={revealed()} else={<T color={c().muted}>内容已收起</T>}>
            <If when={props.editable} else={<Scroll style={{ height: 400, backgroundColor: c().soft2 }}><View style={{ padding: 16 }}>
              {(current()?.text || "此文件暂无内容").split("\n").map((line, index) => <View style={{ flexDirection: "row", gap: 14, minHeight: 22 }}><T mono size={12} color={c().faint} style={{ width: 32 }}>{index + 1}</T><T mono size={12} selectable color={line.trim().startsWith("#") ? c().muted : /^(import |from |def |class |return |if |try:|except )/.test(line.trim()) ? c().blue : c().ink} style={{ flex: 1, minWidth: 0 }}>{line || " "}</T></View>)}
            </View></Scroll>}>
              <Input accessibilityLabel="资料正文" multiline autoCorrect={false} value={current()?.text ?? ""} onChange={({ value }) => update({ text: value })} style={{ fontFamily: MONO, fontSize: 13, minHeight: 400, padding: 16, backgroundColor: c().soft2, color: c().ink, borderWidth: 1, borderColor: c().line }} />
            </If>
          </If>
          <Row style={{ justifyContent: "space-between" }}><T size={10} color={c().muted}>{(current()?.text ?? "").split("\n").length} 行</T><T size={10} color={c().muted}>原文保存 · 不自动运行</T></Row>
          <If when={props.editable}><Toggle title="包含敏感信息" checked={current()?.secret ?? true} onChange={secret => update({ secret })} /></If>
        </If>
      </View>
    </View>
  </View>;
}
