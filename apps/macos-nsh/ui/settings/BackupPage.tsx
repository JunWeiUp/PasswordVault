import { signal, View, Scroll, cleanup } from "nsh";
import { Backup } from "passwordvault/native";
import { Banner, Btn, Group, OptionRow, Row, T, TextBox } from "../kit";
import { errorText, load, onLock, phase, settings, toast, vaultInstance } from "../store";
import { exportBackup, importBackup, backupError, passwordSheet } from "../backup";
import { structuredImport } from "./backup-import";
import { c } from "../theme";

export function BackupPage() {
  const config = signal({url:"",username:"",password:"",folder:"PasswordVault",...settings().webdav});
  const files = signal<any[]>([]); const busy = signal(false); const expanded = signal(true); const connected = signal(false); const status = signal(""); const error = signal(""); const query=signal("");
  cleanup(onLock(()=>{config.set({url:"",username:"",password:"",folder:"PasswordVault"});files.set([]);status.set("");error.set("");}));
  const request = async (action:string, extra:Record<string,unknown>={}) => JSON.parse(await Backup.webdav(vaultInstance, JSON.stringify({action,config:config(),...extra})));
  const run = async (action: "list" | "save") => {
    if (busy()) return;
    busy.set(true); error.set(""); status.set(action==="save"?"正在加密保存连接…":"正在读取备份列表…");
    try { const result=await request(action); if(phase()!=="unlocked")return;
      if(action==="list"){ files.set(result);connected.set(true);expanded.set(false);status.set(`列表已更新 · ${result.length} 份备份`); }
      else { settings.update(s=>({...s,webdav:config()})); status.set("连接设置已加密保存"); }
    } catch(e) { status.set("");error.set(backupError(e)); } finally {busy.set(false);}
  };
  const field=(key:string,label:string,masked=false)=><TextBox label={label} placeholder={label} value={config()[key] ?? ""} masked={masked} onChange={v=>{if(busy())return;config.update(s=>({...s,[key]:v}));files.set([]);connected.set(false);status.set("");}} />;
  const restore=(file:any)=>passwordSheet("恢复 WebDAV 备份", `${file.name}。旧版加密备份需要创建备份时的旧版主密码。`,false,async password=>{
    if(busy())throw new Error("操作进行中，请稍后重试。");busy.set(true);
    try{const result=await request("restore",{url:file.url,password});if(phase()!=="unlocked")return;await load();status.set(`合并完成 · 新增或更新 ${result.imported ?? 0} 条`);}finally{busy.set(false);}
  });
  const upload=()=>passwordSheet("上传完整加密备份","使用新的唯一文件名，不覆盖远端已有备份。",true,async password=>{
    if(busy())throw new Error("操作进行中，请稍后重试。");busy.set(true);
    try{await request("upload",{password});if(phase()!=="unlocked")return;status.set("备份已上传");try{files.set(await request("list"));connected.set(true);}catch{error.set("备份已上传，列表刷新失败。请刷新列表，无需重复上传。");}}finally{busy.set(false);}
  });
  const date=(file:any)=>{const raw=file.modified || file.created;const n=Date.parse(raw);return Number.isFinite(n)?new Date(n).toLocaleString():"时间未知";};
  return <View style={{gap:12}}>
    <T size={20} weight="600">备份与导入</T><T color={c().muted}>备份文件使用单独的备份密码加密，与主密码无关。</T>
    <T weight="600">本机加密备份</T><Group>
      <OptionRow title="导出加密备份" note="选择保存位置，使用新的文件名"><Btn label="导出…" onPress={exportBackup} /></OptionRow>
      <OptionRow title="从备份导入" note="较新记录优先；当前独有记录保留"><Btn label="导入…" onPress={importBackup} /></OptionRow>
    </Group>
    <T weight="600">WebDAV</T>
    <Group><View style={{gap:10,paddingVertical:10}}>
      <Row><T style={{flex:1}}>{connected()?`${config().url} · 已连接`:"备份服务器"}</T><Btn label={expanded()?"收起连接":"修改连接"} disabled={busy()} onPress={()=>expanded.set(!expanded())} /></Row>
      {expanded() && <View style={{gap:8}}>{field("url","HTTPS 服务器地址")}{field("username","服务器用户名")}{field("password","WebDAV 登录密码",true)}{field("folder","备份目录")}
        <T size={12} color={c().muted}>只允许 HTTPS，拒绝重定向，不使用 Cookie。服务器凭据加密保存，备份密码单独输入。</T>
        <Btn label="保存连接设置" disabled={busy()} onPress={()=>run("save")} /></View>}
      <Row><Btn label="连接并刷新" disabled={busy()} onPress={()=>run("list")} /><Btn label="立即备份…" kind="primary" disabled={busy()} onPress={upload} /></Row>
      <T color={c().muted}>{status()}</T><T color={c().red}>{error()}</T>
      <TextBox placeholder="搜索备份文件" value={query()} onChange={v=>query.set(v)} />
      <Scroll style={{maxHeight:240}}><View>
        {files().filter(f=>f.name.toLowerCase().includes(query().toLowerCase())).sort((a,b)=>(Date.parse(b.modified||b.created)||0)-(Date.parse(a.modified||a.created)||0)).map(file=><OptionRow title={file.name} note={`${date(file)} · ${file.size == null ? "大小未知" : `${(file.size/1024).toFixed(1)} KB`}`}><Btn label="恢复…" disabled={busy()} onPress={()=>restore(file)} /></OptionRow>)}
        {!files().length && <T color={c().muted}>{connected()?"此目录还没有备份":"连接后查看备份"}</T>}
      </View></Scroll>
    </View></Group>
    <T weight="600">从其他密码管理器导入</T><Group>
      <OptionRow title="CSV 文件" note="字段映射、预览与重复检测"><Btn label="选择 CSV…" onPress={()=>structuredImport("csv")} /></OptionRow>
      <OptionRow title="1Password（.1pux）" note="保留分类、标签、自定义字段和支持的附件"><Btn label="选择 1PUX…" onPress={()=>structuredImport("1pux")} /></OptionRow>
    </Group>
  </View>;
}
