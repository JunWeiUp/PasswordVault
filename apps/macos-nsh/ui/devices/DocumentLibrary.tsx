import { runnableScript, TerminalPreference } from "./ScriptRun";
import { signal, Scroll, View } from "nsh";
import { Input } from "nsh/base";
import { Btn, Row, T, TextBox, Toggle, copySecret, confirm } from "../kit";
import { c, MONO } from "../theme";
import { documentKind, type DeviceCommand } from "./model";

export function DocumentLibrary(props: { commands: DeviceCommand[]; editable: boolean; canManage?: boolean; busy: boolean; onEdit?: () => void; onRun?: (row: DeviceCommand) => void; onImport: () => void; onChange: (rows: DeviceCommand[]) => void }) {
  const selected = signal(""), revealed = signal(true), query = signal(""), width = signal(800);
  const current = () => props.commands.find(row => row.id === selected()) ?? props.commands[0];
  const manageable = () => props.canManage ?? props.editable;
  const update = (patch: Partial<DeviceCommand>) => {
    if (props.editable && current()) props.onChange(props.commands.map(row => row.id === current()?.id ? { ...row, ...patch } : row));
  };
  const add = () => {
    if (!manageable()) return;
    const row = { id: crypto.randomUUID(), title: "未命名.txt", text: "", secret: true };
    props.onChange([...props.commands, row]); selected.set(row.id); revealed.set(true); if (!props.editable) props.onEdit?.();
  };
  return <View onLayout={e => width.set(e.bounds.size.width)} style={{ gap: 18 }}>
    <Row wrap style={{ justifyContent: "space-between" }}>
      <T color={c().muted}>{props.commands.length} 份资料 · 加密保存</T>
      <Row gap={8}><Btn label="新建资料" disabled={!manageable()} onPress={add} /><Btn label="导入文件…" kind="primary" disabled={!manageable() || props.busy} onPress={props.onImport} /></Row>
    </Row>
    <View style={{ flexDirection: width() < 600 ? "column" : "row", gap: 22, alignItems: "stretch" }}>
      <View style={{ width: width() < 600 ? undefined : 190, gap: 14, flexShrink: 0 }}>
        <T weight="600">资料目录</T>
        <TextBox label="搜索资料" placeholder="搜索文件名…" value={query()} onChange={v => query.set(v)} />
        <Scroll style={{ maxHeight: width() < 600 ? 180 : 460 }}><View style={{ gap: 4 }}>
          {props.commands.filter(row => row.title.toLowerCase().includes(query().toLowerCase())).map(row => <View role="button" accessibilityLabel={`打开 ${row.title || "资料"}`} onPress={() => { selected.set(row.id); revealed.set(true); }} style={{ padding: 12, gap: 8, borderRadius: 6, backgroundColor: current()?.id === row.id ? c().blueSoft : "transparent" }}>
            <T weight="600" size={12}>{row.title || "未命名资料"}</T>
            <T size={11} color={c().muted}>{documentKind(row.title)} · {row.text.split("\n").length} 行</T>
          </View>)}
          <If when={query() && !props.commands.some(row => row.title.toLowerCase().includes(query().toLowerCase()))}><T color={c().muted}>没有匹配的文件</T></If>
        </View></Scroll>
        <T size={11} color={c().muted}>脚本、命令、配置与文本。保留原文，点击运行将在首选终端执行。</T>
      </View>
      <View style={{ flex: 1, minWidth: 0, gap: 12 }}>
        <If when={current()} else={<View style={{ paddingVertical: 40, gap: 12 }}><T size={18} weight="600">还没有资料</T><T color={c().muted}>导入 Python、Shell 或配置文件，也可以新建文本。</T></View>}>
          <T size={19} weight="600" selectable>{current()?.title || "未命名资料"}</T>
          <T size={11} color={c().muted}>{documentKind(current()?.title ?? "")} · {current()?.secret ? "敏感资料" : "文本资料"}</T>
          <If when={props.editable}><TextBox label="完整文件名（含扩展名）" value={current()?.title ?? ""} onChange={title => update({ title })} /></If>
          <Row wrap style={{ backgroundColor: c().soft, padding: 10, gap: 6 }}>
            <T size={11} color={c().muted} style={{ flex: 1 }}>{props.editable ? "编辑中 · 自动保存" : "只读预览"}</T>
            <Btn label={revealed() ? "收起内容" : "显示内容"} onPress={() => revealed.set(!revealed())} />
            <If when={props.onEdit && manageable()}><Btn label={props.editable ? "完成编辑" : "编辑资料"} onPress={props.onEdit} /></If>
            <If when={props.onRun && manageable() && runnableScript(current()?.title ?? "")}><TerminalPreference /><Btn label="点击运行" disabled={!current()?.text || props.busy} onPress={() => { const row = current(); if (row) props.onRun?.(row); }} /></If>
            <Btn label="复制全文" kind="primary" disabled={!current()?.text} onPress={() => void copySecret(current()?.text ?? "", "资料全文")} />
          </Row>
          <If when={revealed()} else={<T color={c().muted}>内容已收起</T>}>
            <If when={props.editable} else={<Scroll style={{ height: 400, backgroundColor: c().soft2 }}><View style={{ padding: 16 }}>
              {(current()?.text || "此文件暂无内容").split("\n").map((line, index) => <View style={{ flexDirection: "row", gap: 14, minHeight: 22 }}><T mono size={12} color={c().faint} style={{ width: 32 }}>{index + 1}</T><T mono size={12} selectable color={line.trim().startsWith("#") ? c().muted : /^(import |from |def |class |return |if |try:|except )/.test(line.trim()) ? c().blue : c().ink} style={{ flex: 1, minWidth: 0 }}>{line || " "}</T></View>)}
            </View></Scroll>}>
              <Input accessibilityLabel="资料正文" multiline autoCorrect={false} value={current()?.text ?? ""} onChange={({ value }) => update({ text: value })} style={{ fontFamily: MONO, fontSize: 13, minHeight: 400, padding: 16, backgroundColor: c().soft2, color: c().ink, borderWidth: 1, borderColor: c().line }} />
            </If>
          </If>
          <Row style={{ justifyContent: "space-between" }}><T size={10} color={c().muted}>{(current()?.text ?? "").split("\n").length} 行</T><T size={10} color={c().muted}>原文保存 · 不自动运行</T></Row>
          <If when={props.editable}><Toggle title="包含敏感信息" checked={current()?.secret ?? true} onChange={secret => update({ secret })} /><Btn label="移除这份资料…" kind="danger" onPress={() => {
            const id = current()?.id;
            confirm({ title: "移除这份资料？", text: "仅移除设备中保存的这份文本，原始文件保留。", ok: "移除资料", danger: true, onConfirm: () => { if (!manageable()) return; props.onChange(props.commands.filter(row => row.id !== id)); selected.set(""); } });
          }} /></If>
        </If>
      </View>
    </View>
  </View>;
}
