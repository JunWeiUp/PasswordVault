import { openScriptRun } from "./ScriptRun";
import { DocumentLibrary } from "./DocumentLibrary";
import { cleanup, signal, Scroll, View } from "nsh";
import { Attachments, Files } from "passwordvault/native";
import { Banner, Btn, Field, Group, openSheet, Row, SheetFooter, SheetTitle, T, TextBox, Toggle, copySecret } from "../kit";
import { call, createItem, dest, edit, errorText, editing, flush, items, load, now, onLock, phase, toast, vaultInstance, type Item, type ItemType } from "../store";
import { openSettings } from "../Settings";
import { blankDevice, connectionCommand, importedDevice, planDeviceImport, type DeviceDocument, type DeviceImportGroup, type DeviceData, type DeviceFile } from "./model";
export { deviceSubtitle, deviceSearchText, connectionCommand } from "./model";

export const devicesWarning = "启用后升级为格式 7，并先保留加密快照。旧版客户端无法打开此库，需更新客户端。中继同步将暂停；即使全部升级，也需后续版本完成能力协商后才能恢复同步。";
export function askEnableDevices(done?: () => void) {
  openSheet({ width: 560, render: close => <Enable close={close} done={done} /> });
}
function Enable(props: { close: () => void; done?: () => void }) {
  const password = signal(""), accepted = signal(false), busy = signal(false), error = signal("");
  let alive = true;
  cleanup(() => { alive = false; password.set(""); });
  cleanup(onLock(() => { password.set(""); props.close(); }));
  const enable = async () => {
    if (!accepted() || !password() || busy()) return;
    busy.set(true); error.set("");
    try {
      if (!(await flush())) throw new Error("请先保存当前修改");
      await call({ op: "devices-enable", currentPassword: password(), confirm: true });
      password.set(""); await load();
      if (alive && phase() === "unlocked") { props.close(); props.done?.(); }
    } catch (e) { if (alive) error.set(errorText(e)); }
    finally { if (alive) busy.set(false); }
  };
  return <View style={{ gap: 14 }}><SheetTitle title="启用设备与服务" text="这是一次密码库格式升级。" />
    <Banner tone="warn" title="旧客户端需要更新，升级后暂停同步">{devicesWarning}</Banner>
    <Toggle title="我已了解兼容性影响，并接受暂停同步" checked={accepted()} onChange={v => accepted.set(v)} />
    <TextBox masked label="当前主密码" placeholder="输入主密码确认" value={password()} onChange={v => password.set(v)} onSubmit={() => void enable()} />
    <If when={error()}><Banner tone="err" title={error()} /></If>
    <SheetFooter><Btn label="取消" disabled={busy()} onPress={props.close} /><Btn label="备份并升级" kind="primary" disabled={busy() || !accepted() || !password()} onPress={() => void enable()} /></SheetFooter>
  </View>;
}
export async function newDevice() {
  if (phase() !== "unlocked") return;
  const status = await call({ op: "devices-status" });
  if (!status.enabled) { askEnableDevices(() => void newDevice()); return; }
  await createItem("device" as ItemType, { title: "未命名设备", device: blankDevice() });
}

export async function importDeviceDocuments() {
  if (phase() !== "unlocked") return;
  try {
    const status = await call({ op: "devices-status" });
    if (phase() !== "unlocked") return;
    if (!status.enabled) { askEnableDevices(() => void importDeviceDocuments()); return; }
    openSheet({ width: 720, render: close => <DeviceImport close={close} pick={async () => JSON.parse(await Files.pickDeviceDocuments(vaultInstance))} /> });
  } catch (e) { toast(errorText(e)); }
}
export function DeviceImport(props: { close: () => void; pick: () => Promise<DeviceDocument[]> }) {
  const groups = signal<DeviceImportGroup[]>([]), skipped = signal<string[]>([]), busy = signal(false), error = signal(""), saved = signal(0), chosen = signal(false);
  let alive = true;
  const clear = () => { groups.set([]); skipped.set([]); };
  cleanup(() => { alive = false; clear(); });
  cleanup(onLock(() => { clear(); props.close(); }));
  const active = () => alive && phase() === "unlocked";
  const count = () => groups().reduce((n, g) => n + g.documents.length, 0);
  const choose = async () => {
    if (busy() || !active()) return;
    busy.set(true); error.set("");
    try {
      const documents = await props.pick();
      if (!active() || !documents.length) return;
      if (!(await flush()) || !active()) throw new Error("请先保存当前修改");
      const current = await call<{ items: Item[] }>({ op: "list", summaries: true });
      if (!active()) return;
      const plan = planDeviceImport(documents, current.items);
      groups.set(plan.groups); skipped.set(plan.skipped); chosen.set(true); saved.set(0);
    } catch (e) { if (active()) error.set(errorText(e)); }
    finally { if (alive) busy.set(false); }
  };
  const commit = async () => {
    if (busy() || !active() || !count() || groups().some(g => !g.title.trim())) return;
    busy.set(true); error.set("");
    try {
      if (!(await flush()) || !active()) throw new Error("请先保存当前修改");
      const current = await call<{ items: Item[] }>({ op: "list", summaries: true });
      if (!active()) return;
      const fresh = planDeviceImport(groups().flatMap(g => g.documents), current.items);
      if (fresh.skipped.length) {
        const allowed = new Set(fresh.groups.flatMap(g => g.documents.map(d => d.id)));
        groups.set(groups().map(g => ({ ...g, documents: g.documents.filter(d => allowed.has(d.id)) })).filter(g => g.documents.length));
        skipped.set([...skipped(), ...fresh.skipped]);
        error.set("检测到已有资料，已跳过重复项。请检查剩余预览后重新确认。"); return;
      }
      const pending = [...groups()];
      for (const group of pending) {
        if (!active()) return;
        if (current.items.some(i => i.id === group.id)) throw new Error("设备标识已存在，请重新选择文件");
        const at = now();
        const item: Item = { id: group.id, type: "device", title: group.title.trim(), username: "", note: "", tags: [], noteFormat: "plain", isDeleted: false, isFavorite: false, isPinned: false, createdAt: at, updatedAt: at, device: importedDevice(group.documents) };
        await call({ op: "save", item });
        if (!active()) return;
        items.update(list => [...list.filter(i => i.id !== item.id), item]);
        saved.set(saved() + 1); groups.set(groups().filter(g => g.id !== group.id));
      }
      if (active()) dest.set("devices");
    } catch (e) { if (active()) error.set(`${errorText(e)} 已保存的设备会保留，可重试剩余资料。`); }
    finally { if (alive) busy.set(false); }
  };
  return <View style={{ gap: 12 }}>
    <SheetTitle title="导入设备资料" text="选择脚本、配置或文本文件，只读取 UTF-8 文本，不执行脚本，也不修改或删除原文件。" />
    <T size={12}>最多 32 个文件，每个 256 KiB、合计 1 MiB。按文件名第一个“-”之前分设备，可修改名称；所有原文均标为敏感。主机和服务配置留空，避免误解析脚本。</T>
    <Btn label="选择资料文件…" disabled={busy()} onPress={() => void choose()} />
    <If when={chosen()}><T weight="600">预览：新增 {groups().length} 台设备 · {count()} 条敏感资料</T></If>
    <If when={skipped().length}><Banner tone="warn" title={`已跳过 ${skipped().length} 个重复文件`}>当前设备中已有这些资料：{skipped().join("、")}。不会覆盖已有设备；回收站中的资料不影响重新导入。</Banner></If>
    <If when={saved()}><Banner tone="info" title={`已新增 ${saved()} 台设备`}>原文件保留；资料位于设备的“脚本与资料”。</Banner></If>
    <If when={error()}><Banner tone="err" title="导入未完成">{error()}</Banner></If>
    <Scroll style={{ maxHeight: 340 }}><View style={{ gap: 10 }}>{groups().map(group => <Group>
      <TextBox label={`设备名称 ${group.title}`} value={group.title} onChange={title => { if (!busy()) groups.set(groups().map(g => g.id === group.id ? { ...g, title } : g)); }} />
      <T>{group.documents.length} 条资料 · 仅新增，不覆盖同名设备</T>
      {group.documents.map(document => <View><T size={12}>{document.name} · {document.size} bytes · 敏感</T><Field label="原文预览" value={document.text} secret multiline mono nocopy /></View>)}
    </Group>)}</View></Scroll>
    <SheetFooter><Btn label={saved() ? "完成" : "取消"} disabled={busy()} onPress={props.close} /><Btn label="确认新增设备" kind="primary" disabled={busy() || !count() || groups().some(g => !g.title.trim())} onPress={() => void commit()} /></SheetFooter>
  </View>;
}

export function DeviceDetail(props: { item: Item; editable?: boolean; onOpenSettings?: () => void }) {
  const tab = signal("commands"), busy = signal(false), error = signal("");
  let alive = true; const owner = props.item.id;
  cleanup(() => { alive = false; });
  const data = (): DeviceData => props.item.device;
  const writable = () => !props.item.isDeleted && phase() === "unlocked";
  const set = (key: keyof DeviceData, value: unknown) => { if (writable()) edit(owner, i => { i.device = { ...i.device, [key]: value }; }); };
  const importDocuments = async () => {
    if (!writable() || busy()) return;
    busy.set(true); error.set("");
    try {
      const documents: DeviceDocument[] = JSON.parse(await Files.pickDeviceDocuments(vaultInstance));
      if (!alive || !writable() || !documents.length) return;
      const rows = [...data().commands];
      let added = 0;
      for (const d of documents) {
        if (rows.some(r => r.title === d.name && r.text === d.text)) continue;
        rows.push({ id: d.id, title: d.name, text: d.text, secret: true }); added++;
      }
      set("commands", rows);
      if (!(await flush())) throw new Error("资料尚未保存，请重试保存");
      toast(added ? `已导入 ${added} 份资料` : "所选资料已存在于此设备");
    } catch (e) { if (alive) error.set(errorText(e)); }
    finally { if (alive) busy.set(false); }
  };
  const importFile = async () => {
    if (!writable() || busy()) return; busy.set(true); error.set("");
    try {
      if (!(await flush())) throw new Error("请先保存当前修改");
      const path = await Files.pickOpen("添加设备资料文件", []);
      if (!path || !alive || !writable()) return;
      const meta = JSON.parse(await Attachments.importFile(vaultInstance, owner, path));
      if (!alive || !writable()) return;
      set("files", [...data().files, { attachmentId: meta.id, name: meta.name, mime: meta.mime, size: meta.size }]);
      if (!(await flush())) throw new Error("附件引用尚未保存，请重试保存");
    } catch (e) { if (alive) error.set(errorText(e)); }
    finally { if (alive) busy.set(false); }
  };
  return <View><Row gap={8} style={{ padding: 18 }}>{[["commands", "脚本与资料"], ["ai", "AI 访问"]].map(([key, label]) => <Btn label={label} kind={tab() === key ? "primary" : "ghost"} onPress={() => tab.set(key)} />)}</Row>
    <View style={{ paddingVertical: 16, gap: 16 }}>
      <If when={error()}><Banner tone="err" title={error()} /></If>
      <If when={tab() === "commands"}><DocumentLibrary commands={data().commands} editable={!!props.editable && writable()} canManage={writable()} onEdit={() => editing.set(!editing())} onRun={row => void openScriptRun(row)} busy={busy()} onChange={rows => set("commands", rows)} onImport={() => void importDocuments()} /></If>
      <If when={tab() === "commands" && data().files.length > 0}><Banner tone="info" title="文件加密保存，脚本不会执行">文本预览上限为 256 KiB，二进制文件只显示资料信息。附件内容默认视为敏感。</Banner>
        <If when={!data().files.length}><T>暂无附件。</T></If>
        {data().files.map(file => <Group><T weight="600">{file.name}</T><T>{file.size} bytes · {file.mime}</T><Row gap={8}>
          <Btn label="查看文本…" onPress={() => openDeviceFile(owner, file)} /><Btn label="移除引用" disabled={!writable()} onPress={() => set("files", data().files.filter(f => f.attachmentId !== file.attachmentId))} />
        </Row></Group>)}<Btn label="添加文件…" disabled={!writable() || busy()} onPress={() => void importFile()} />
      </If>
      <If when={tab() === "ai"}><Group><T size={18} weight="600">由你控制 AI 访问</T><T>在设置中管理客户端及授权。主机配置、敏感字段与附件应分别授权；锁定后停止读取。</T><Btn label="打开 AI 访问设置" onPress={() => props.onOpenSettings ? props.onOpenSettings() : openSettings("ai")} /></Group></If>
    </View></View>;
}
function openDeviceFile(id: string, file: DeviceFile) {
  openSheet({ width: 680, render: close => <FilePreview id={id} file={file} close={close} /> });
}
function FilePreview(props: { id: string; file: DeviceFile; close: () => void }) {
  const text = signal(""), error = signal(""); let alive = true;
  cleanup(() => { alive = false; text.set(""); });
  cleanup(onLock(() => { text.set(""); props.close(); }));
  void call({ op: "devices-file-read", id: props.id, attachmentId: props.file.attachmentId }).then(result => { if (alive && phase() === "unlocked") text.set(result.text); }).catch(e => { if (alive) error.set(errorText(e)); });
  return <View style={{ gap: 12 }}><SheetTitle title={props.file.name} text="敏感内容 · 仅预览，不执行" /><If when={error()}><Banner tone="err" title="无法预览此文件">文件可能为二进制、超过 256 KiB 或已移除。</Banner></If><Scroll style={{ maxHeight: 380 }}><T mono selectable>{text()}</T></Scroll><SheetFooter><Btn label="复制文本" disabled={!text()} onPress={() => copySecret(text(), "文件文本")} /><Btn label="关闭" onPress={props.close} /></SheetFooter></View>;
}
