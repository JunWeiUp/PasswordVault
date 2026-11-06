import { signal, Scroll, View } from "nsh";
import { Backup, Files } from "passwordvault/native";
import { Banner, Btn, openSheet, Row, SheetFooter, SheetTitle, T, TextBox, Toggle } from "../kit";
import { errorText, load, phase, toast, vaultInstance } from "../store";
import { flushBackup } from "../backup";
import { c } from "../theme";

export async function structuredImport(format: "csv" | "1pux") {
  try {
    const path = await Files.pickOpen(`导入 ${format.toUpperCase()}`, [format]);
    if (!path || phase() !== "unlocked") return;
    const preview = signal<any>(null); const mapping = signal<Record<string,string>>({});
    const choices = signal<Record<string,string>>({}); const busy = signal(false); const error = signal(""); const stale = signal(false);
    const review = async () => {
      busy.set(true); error.set("");
      try { await flushBackup(); const result = JSON.parse(await Backup.structured(vaultInstance,path,JSON.stringify({op:"import-preview",format,mapping:mapping()}))); if (phase() !== "unlocked") return; preview.set(result); choices.set({}); stale.set(false); }
      catch(e) { error.set(errorText(e)); } finally { busy.set(false); }
    };
    await review();
    if (phase() !== "unlocked") return;
    openSheet({ width: 760, render: close => {
      const commit = async () => {
        if (busy() || stale() || !preview()) return;
        busy.set(true); error.set("");
        try { await flushBackup(); await Backup.structured(vaultInstance,path,JSON.stringify({op:"import-commit",format,mapping:mapping(),choices:choices(),fingerprint:preview().fingerprint})); if (phase() !== "unlocked") return; await load(); close(); preview.set(null); toast("导入完成"); }
        catch(e) { error.set(errorText(e)); } finally { busy.set(false); }
      };
      return <View style={{gap:10,maxHeight:650}}>
        <SheetTitle title={`导入 ${format.toUpperCase()}`} text="重复项默认跳过。可明确添加为独立记录，不覆盖现有条目。" />
        <Scroll style={{maxHeight:470}}><View style={{gap:10}}>
          {format === "csv" && <View style={{gap:6}}><T weight="600">字段映射</T><T size={12}>可用列：{(preview()?.columns ?? []).join("、")}</T>
            {[["title","标题"],["username","用户名"],["password","密码"],["url","网址"],["notes","备注"]].map(([key,label]) => <Row><T style={{width:70}}>{label}</T><TextBox placeholder="自动识别（或输入完整列名）" value={mapping()[key] ?? ""} onChange={v=>{mapping.update(m=>{const n={...m};if(v)n[key]=v;else delete n[key];return n;});stale.set(true);}} /></Row>)}
            <Btn label="更新预览" disabled={busy()} onPress={review} /></View>}
          <T weight="600">预览 · {preview()?.rows?.length ?? 0} 条</T>
          {(preview()?.rows ?? []).map((row:any) => <View style={{padding:10,borderBottomWidth:1,borderBottomColor:c().line2,gap:4}}>
            <Toggle title={row.item.title || "未命名"} note={`${row.item.type} · ${row.duplicateIds.length ? "检测到重复，默认跳过" : "新记录"}`} checked={(choices()[row.index] ?? (row.duplicateIds.length ? "skip" : "add")) === "add"} disabled={busy()} onChange={v=>choices.update(s=>({...s,[row.index]:v?"add":"skip"}))} />
            <T size={12}>{row.item.username ?? ""} · {row.item.url ?? ""} · 密码已隐藏</T>
            {(row.warnings ?? []).map((w:string)=><T size={11} color={c().orange}>{w}</T>)}
          </View>)}
          {(preview()?.failures ?? []).map((f:any)=><T color={c().red}>{JSON.stringify(f)}</T>)}
          <Banner tone="warn" title="保留原文件">未映射字段和支持的来源资料会加密保存。源文件不会删除；导入可能升级格式，旧客户端可能无法打开。</Banner>
        </View></Scroll>
        <T color={c().red}>{error() || (stale() ? "字段映射已修改，请更新预览。" : "")}</T>
        <SheetFooter><Btn label="取消" disabled={busy()} onPress={()=>{preview.set(null);close();}} /><Btn label={busy()?"处理中…":"确认导入"} kind="primary" disabled={busy() || stale() || !preview()?.rows?.length} onPress={commit} /></SheetFooter>
      </View>;
    }});
  } catch(e) { toast(errorText(e)); }
}
