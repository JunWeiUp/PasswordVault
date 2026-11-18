import { openScriptRun } from "./ScriptRun";
import { DocumentLibrary } from "./DocumentLibrary";
import { cleanup, openUrl, signal, Scroll, View, type JSX } from "nsh";
import { Attachments, Files } from "passwordvault/native";
import { Banner, Btn, Card, Field, Group, IconTile, openSheet, Row, Segmented, SheetFooter, SheetTitle, T, TextBox, Toggle, confirm, copySecret } from "../kit";
import { Icon } from "../icons";
import { desktopCapabilities } from "../native";
import { call, createItem, dest, edit, errorText, editing, flush, items, load, now, onLock, phase, toast, vaultInstance, type Item, type ItemType } from "../store";
import { cfg as aiCfg, change as aiChange } from "../ai";
import { c } from "../theme";
import { blankDevice, connectionCommand, deviceSubtitle, deviceTitle, importedDevice, planDeviceImport, type DeviceDocument, type DeviceImportGroup, type DeviceData, type DeviceFile, type DeviceService } from "./model";
export { deviceTitle, deviceSubtitle, deviceSearchText, connectionCommand } from "./model";

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
  await createItem("device" as ItemType, { title: "", device: blankDevice() });
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

const SERVICE_KINDS: [DeviceService["kind"], string][] = [["ssh", "SSH"], ["vnc", "VNC"], ["browser", "网页"], ["custom", "自定义"]];
const DEFAULT_PORT: Record<DeviceService["kind"], string> = { ssh: "22", vnc: "5900", browser: "80", custom: "" };
const validPort = (value: string) => /^\d+$/.test(value.trim()) && Number(value) >= 1 && Number(value) <= 65535;
function ServiceEditor(props: { close: () => void; onSave: (service: DeviceService) => void }) {
  const name = signal(""), kind = signal<DeviceService["kind"]>("ssh"), remotePort = signal("22"), localPort = signal("22"), path = signal("");
  cleanup(onLock(props.close));
  const pick = (value: string) => { const next = value as DeviceService["kind"]; if (remotePort() === DEFAULT_PORT[kind()]) remotePort.set(DEFAULT_PORT[next]); if (localPort() === DEFAULT_PORT[kind()]) localPort.set(DEFAULT_PORT[next]); kind.set(next); };
  const ready = () => !!name().trim() && validPort(remotePort()) && validPort(localPort());
  const labeled = (label: string, child: JSX.Element) => <View style={{ flex: 1, minWidth: 0, gap: 6 }}><T size={11.5} color={c().muted}>{label}</T>{child}</View>;
  return <View style={{ gap: 14 }}><SheetTitle title="添加服务入口" text="保存服务名称、端口和路径。PasswordVault 不会自动启动服务。" />
    {labeled("类型", <Segmented label="服务类型" tabs={SERVICE_KINDS} value={kind()} onChange={pick} />)}
    {labeled("服务名称", <TextBox label="服务名称" placeholder="例如 管理后台" value={name()} onChange={value => name.set(value)} />)}
    <Row gap={12} style={{ alignItems: "flex-start" }}>{labeled("远程端口", <TextBox label="远程端口" value={remotePort()} onChange={value => remotePort.set(value)} />)}{labeled("本地端口", <TextBox label="本地端口" value={localPort()} onChange={value => localPort.set(value)} />)}</Row>
    <If when={(remotePort() && !validPort(remotePort())) || (localPort() && !validPort(localPort()))}><T size={11} color={c().red}>端口需为 1–65535 的整数。</T></If>
    {labeled("路径（可选）", <TextBox label="路径（可选）" placeholder="/admin" value={path()} onChange={value => path.set(value)} />)}
    <SheetFooter><Btn label="取消" onPress={props.close} /><Btn label="保存服务" kind="primary" disabled={!ready()} onPress={() => { const raw = path().trim(); props.onSave({ id: crypto.randomUUID(), name: name().trim(), kind: kind(), remotePort: Number(remotePort()), localPort: Number(localPort()), path: raw && !raw.startsWith("/") ? `/${raw}` : raw }); props.close(); }} /></SheetFooter>
  </View>;
}

const serviceAddress = (d: DeviceData, s: DeviceService) => `${d.host}:${s.remotePort}${s.path || ""}`;
// The app may only open https URLs (nsh.json capabilities), so web services always open over https.
const serviceUrl = (d: DeviceData, s: DeviceService) => `https://${d.host}${s.remotePort === 443 ? "" : `:${s.remotePort}`}${s.path || ""}`;
const runInTerminal = (title: string, text: string) => void openScriptRun({ id: crypto.randomUUID(), title, text, secret: false });

function ConnectionCell(props: { label: string; value: string; editing: boolean; mono?: boolean; onChange: (value: string) => void }) {
  return <View style={{ flex: 1, minWidth: 150, borderWidth: 1, borderColor: c().line, borderRadius: 10, paddingHorizontal: 12, paddingVertical: 10, gap: 4, backgroundColor: c().surface }}>
    <T size={11} color={c().muted}>{props.label}</T>
    <If when={props.editing} else={<Row gap={6}><T size={13} weight="500" mono={props.mono} selectable color={props.value ? c().ink : c().faint} style={{ flex: 1, minWidth: 0 }} lines={1}>{props.value || "未填写"}</T><If when={props.value}><View role="button" accessibilityLabel={`复制${props.label}`} tooltip={`复制${props.label}`} onPress={() => void copySecret(props.value, props.label)} style={{ padding: 3, borderRadius: 5, cursor: "pointer" }} hoverStyle={{ backgroundColor: c().blueSoft }}><Icon name="copy" size={13} tint={c().muted} /></View></If></Row>}>
      <TextBox label={props.label} value={props.value} mono={props.mono} onChange={props.onChange} />
    </If>
  </View>;
}

function DeviceConnectionView(props: { data: DeviceData; editing: boolean; writable: boolean; set: (key: keyof DeviceData, value: unknown) => void; onAdd: () => void; onRemove: (service: DeviceService) => void }) {
  const d = () => props.data;
  const canRun = () => desktopCapabilities.terminal && !!d().host.trim();
  return <View style={{ gap: 16 }}>
    <Row gap={10} wrap style={{ alignItems: "stretch" }}>
      <ConnectionCell label="主机" mono value={d().host} editing={props.editing} onChange={value => props.set("host", value.trim())} />
      <ConnectionCell label="用户名" value={d().username} editing={props.editing} onChange={value => props.set("username", value.trim())} />
      <ConnectionCell label="端口" mono value={String(d().port || "")} editing={props.editing} onChange={value => { if (value === "" || validPort(value)) props.set("port", value === "" ? 22 : Number(value)); }} />
    </Row>
    <Banner tone="info" icon="tools" title="连接交给外部终端" style={{ marginBottom: 0, alignItems: "center" }} actions={<><Btn label="复制命令" icon="copy" disabled={!d().host} onPress={() => void copySecret(connectionCommand(d()), "连接命令")} /><Btn label="打开外部终端" disabled={!canRun()} tooltip={!desktopCapabilities.terminal ? "此平台暂未开放终端运行" : !d().host ? "请先填写主机" : undefined} onPress={() => runInTerminal("connect.sh", connectionCommand(d()))} /></>}>PasswordVault 只生成命令并交给首选终端，不在应用内执行，也不会把密码拼进命令。</Banner>
    <Row gap={8}><T size={15} weight="600" style={{ flex: 1 }}>服务入口</T><Btn label="添加服务" icon="plus" kind="ghost" disabled={!props.writable} onPress={props.onAdd} /></Row>
    <If when={d().services.length > 0} else={<Card><T size={12} color={c().muted}>还没有服务入口。添加 SSH、VNC、网页或自定义服务后，可以一键复制入口或交给外部应用打开。</T></Card>}>
      <Row gap={12} wrap style={{ alignItems: "stretch" }}>{d().services.map(service => <Card style={{ flex: 1, minWidth: 260, flexBasis: 260 }}>
        <Row gap={10}><IconTile name={service.kind === "browser" ? "browser" : service.kind === "ssh" ? "tools" : "link"} size={34} /><View style={{ flex: 1, minWidth: 0, gap: 2 }}><T size={13} weight="600" lines={1}>{service.name}</T><T size={11} color={c().muted}>{SERVICE_KINDS.find(([k]) => k === service.kind)?.[1] ?? service.kind} · 远程 {service.remotePort} → 本地 {service.localPort}</T></View></Row>
        <View style={{ backgroundColor: c().soft2, borderRadius: 7, paddingHorizontal: 10, paddingVertical: 7 }}><T mono size={11.5} selectable lines={1}>{d().host ? serviceAddress(d(), service) : `未填写主机:${service.remotePort}${service.path || ""}`}</T></View>
        <Row gap={8} wrap>
          <Btn label="复制入口" icon="copy" disabled={!d().host} onPress={() => void copySecret(serviceAddress(d(), service), "服务入口")} />
          <If when={service.kind === "browser"}><Btn label="在浏览器打开" tooltip="以 https 打开" disabled={!d().host} onPress={() => void openUrl(serviceUrl(d(), service)).catch(() => toast("无法交给外部应用打开"))} /></If>
          <If when={service.kind !== "browser"}><Btn label="复制隧道命令" disabled={!d().host} onPress={() => void copySecret(connectionCommand(d(), service), "隧道命令")} /></If>
          <View style={{ flex: 1 }} />
          <Btn label="移除" kind="danger" disabled={!props.writable} onPress={() => props.onRemove(service)} />
        </Row>
      </Card>)}</Row>
    </If>
    <T size={11.5} color={c().muted}>服务名称、端口和路径可作为普通字段被 AI 查询；密码、私钥和脚本原文始终单独处理，服务不会因被 AI 找到而自动启动。</T>
  </View>;
}

const deviceTab = signal("");
export function DeviceDetail(props: { item: Item; editable?: boolean }) {
  const busy = signal(false), error = signal("");
  let alive = true; const owner = props.item.id;
  cleanup(() => { alive = false; });
  const data = (): DeviceData => props.item.device;
  const writable = () => !props.item.isDeleted && phase() === "unlocked";
  const set = (key: keyof DeviceData, value: unknown) => { if (writable()) edit(owner, i => { i.device = { ...i.device, [key]: value }; }); };
  const addService = () => openSheet({ width: 520, render: close => <ServiceEditor close={close} onSave={service => { set("services", [...data().services, service]); void flush().then(ok => ok && toast("服务入口已保存")); }} /> });
  const removeService = (service: DeviceService) => confirm({ title: `移除“${service.name}”？`, text: "只移除这个服务入口，不影响主机上的服务。", ok: "移除", danger: true, onConfirm: () => { set("services", data().services.filter(row => row.id !== service.id)); void flush(); } });
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
  const sub = () => deviceTab() || (data().host || data().services.length ? "overview" : "commands");
  // Explicit per-file classification for AI reads, never inferred from extension or MIME type.
  const aiOrdinary = (file: DeviceFile) => aiCfg().aiAccessOrdinaryFiles?.[owner]?.[file.attachmentId] === true;
  const toggleAiOrdinary = (file: DeviceFile) => {
    const next = !aiOrdinary(file);
    const apply = () => void aiChange({ op: "configure", aiAccessOrdinaryFiles: { ...aiCfg().aiAccessOrdinaryFiles, [owner]: { ...aiCfg().aiAccessOrdinaryFiles?.[owner], [file.attachmentId]: next } } });
    if (!next) return apply();
    confirm({ title: `允许 AI 读取“${file.name}”？`, text: "已授权此设备的 AI 客户端可以读取全文，内容会进入 AI 对话。请确认文件不含密码、令牌、节点链接或私钥。", ok: "标记为普通资料", onConfirm: apply });
  };
  const files = <Card title="附件" note="文件加密保存，脚本不会执行。文本预览上限 256 KiB，二进制文件只显示资料信息。" right={<Btn label="添加文件…" icon="plus" kind="ghost" disabled={!writable() || busy()} onPress={() => void importFile()} />}>
    <If when={data().files.length > 0} else={<T size={12} color={c().faint}>暂无附件。</T>}>
      <View>{data().files.map((file, index) => <Row gap={10} style={{ paddingVertical: 8, borderBottomWidth: index === data().files.length - 1 ? 0 : 1, borderBottomColor: c().line2 }}>
        <IconTile name="paper" />
        <View style={{ flex: 1, minWidth: 0, gap: 2 }}><T size={12.5} weight="500" lines={1}>{file.name}</T><T size={11} color={c().muted}>{formatSize(file.size)} · {file.mime || "未知类型"}</T></View>
        <Btn label="查看文本…" onPress={() => openDeviceFile(owner, file)} />
        <If when={desktopCapabilities.ai}><Btn label={aiOrdinary(file) ? "AI 可读" : "AI 不可读"} kind="ghost" tooltip="标记为普通资料后，已授权的 AI 客户端可以读取此附件；请确认文件不含密码、令牌或私钥" onPress={() => toggleAiOrdinary(file)} /></If>
        <Btn label="移除引用" kind="danger" disabled={!writable()} onPress={() => confirm({ title: `移除“${file.name}”？`, text: "只移除设备中的附件引用。", ok: "移除", danger: true, onConfirm: () => { set("files", data().files.filter(f => f.attachmentId !== file.attachmentId)); void flush(); } })} />
      </Row>)}</View>
    </If>
  </Card>;
  return <View style={{ gap: 18 }}>
    <Row gap={16}>
      <View style={{ width: 60, height: 60, borderRadius: 60 * 0.24, borderWidth: 1, borderColor: c().line, backgroundColor: c().surface, alignItems: "center", justifyContent: "center" }}>
        <Icon name="server" size={30} tint="#617795" />
      </View>
      <View style={{ flex: 1, minWidth: 0, gap: 4 }}>
        <If when={!!props.editable && writable()} else={<T size={26} weight="600" lines={2} selectable>{deviceTitle(props.item)}</T>}>
          <TextBox label="设备标题" placeholder="设备标题（可选，留空时显示主机）" value={props.item.title ?? ""} onChange={value => { if (writable()) edit(owner, i => { i.title = value; }); }} />
        </If>
        <T size={12} color={c().muted} lines={1}>{deviceSubtitle(props.item)}{data().commands.length && data().host ? ` · ${data().commands.length} 条资料` : ""}</T>
      </View>
    </Row>
    <If when={error()}><Banner tone="err" title={error()} style={{ marginBottom: 0 }} /></If>
    <>
      <Segmented label="设备资料视图" tabs={[["overview", "连接与服务"], ["commands", "脚本与资料"]]} value={sub()} onChange={value => deviceTab.set(value)} />
      <If when={sub() === "overview"}><DeviceConnectionView data={data()} editing={!!props.editable && writable()} writable={writable()} set={set} onAdd={addService} onRemove={removeService} /></If>
      <If when={sub() === "commands"}>
        <DocumentLibrary commands={data().commands} editable={!!props.editable && writable()} canManage={writable()} onEdit={() => editing.set(!editing())} onRun={row => void openScriptRun(row)} busy={busy()} onChange={rows => set("commands", rows)} onImport={() => void importDocuments()} />
        {files}
      </If>
    </>
  </View>;
}
const formatSize = (size: number) => size < 1024 ? `${size} B` : size < 1048576 ? `${(size / 1024).toFixed(1)} KiB` : `${(size / 1048576).toFixed(1)} MiB`;
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
