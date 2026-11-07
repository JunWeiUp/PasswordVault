import { Canvas, effect, signal, View } from "nsh";
import { Files, QrImport, Relay } from "passwordvault/native";
import { Banner, Btn, copySecret, Field, Group, Row, SectionHead, T, TextBox, confirm, openSheet, SheetTitle, SheetFooter } from "../kit";
import { call, createItem, edit, items, select, dest, errorText, toast, type Item } from "../store";
import { c } from "../theme";
import { formatCode, secondsLeft, useCode } from "../totp";
import { normalizeSecret, validPeriod, setupLink } from "./model";
import { EntryHero, EntryMeta, change, type EntryProps } from "./shared";
export async function parseCode(uri:string) { const parsed = await call({op:"parse-totp",uri:uri.trim()}); return {...parsed, issuer:parsed.title}; }
async function pickCode() {
  const path=await Files.pickOpen("选择验证码二维码图片",["png","jpg","jpeg","gif","webp"]);
  return path ? await parseCode(await QrImport.fromImage(path)) : null;
}
export function askAddCode(apply?: (fields:any)=>Promise<void>|void) {
  const tab=signal("图片导入"), uri=signal(""), issuer=signal(""), username=signal(""), secret=signal(""), period=signal("30"), error=signal(""), busy=signal(false);
  const submit=async(close:()=>void)=>{if(busy())return;busy.set(true);error.set("");try {
    const parsed=tab()==="图片导入" ? await pickCode() : await parseCode(tab()==="粘贴链接" ? uri() : setupLink({title:issuer(),username:username(),secret:normalizeSecret(secret()),period:Number(period())}));
    if(!parsed)return;
    if(apply)await apply(parsed);else if (!(await createItem("totp",parsed))) throw new Error("保存失败，请重试。");
    secret.set("");uri.set("");close();
  }catch(e){error.set(errorText(e));}finally{busy.set(false);}};
  openSheet({width:570,render:close=><><SheetTitle title="添加验证码" text="二维码只在本机解析。支持图片、设置链接及手动密钥；暂不支持相机或屏幕扫描。" />
    <Row gap={8}>{["图片导入","粘贴链接","手动输入"].map(t=><Btn label={t} kind={tab()===t?"primary":"default"} onPress={()=>{tab.set(t);error.set("");}} />)}</Row>
    <If when={tab()==="图片导入"}><T>选择仅包含一个验证码二维码的图片（最大 20 MB）。</T></If>
    <If when={tab()==="粘贴链接"}><TextBox label="otpauth 设置链接" value={uri()} masked onChange={v=>uri.set(v)} /></If>
    <If when={tab()==="手动输入"}><TextBox label="发行方" value={issuer()} onChange={v=>issuer.set(v)} /><TextBox label="账号" value={username()} onChange={v=>username.set(v)} /><TextBox label="设置密钥" value={secret()} masked onChange={v=>secret.set(v)} /><TextBox label="周期（秒）" value={period()} onChange={v=>period.set(v)} /><T>SHA1 · 6 位</T></If>
    <If when={error()}><Banner tone="err" title="无法导入">{error()}</Banner></If>
    <SheetFooter><Btn label="取消" disabled={busy()} onPress={()=>{secret.set("");uri.set("");close();}} /><Btn label={tab()==="图片导入"?"选择图片并导入":"验证并保存"} kind="primary" disabled={busy()||(tab()==="手动输入"&&!validPeriod(period()))} onPress={()=>void submit(close)} /></SheetFooter></>});
}
export function CodePreview(p:{item:Item; large?:boolean}) {
  const period=()=>validPeriod(p.item.period??30)?Number(p.item.period??30):30;
  const code=useCode(()=>p.item.secret??"",period), next=signal("");
  let generation=0, last="";
  effect(()=>{secondsLeft(period());const s=p.item.secret;const time=Math.floor(Date.now()/1000);const key=`${s}|${period()}|${Math.floor(time/period())}`;if(key===last)return;last=key;const n=++generation;next.set("");if(s)void call({op:"totp",secret:s,period:period(),time:time+period()}).then(r=>{if(n===generation)next.set(r.code);}).catch(()=>{});});
  const low=()=>secondsLeft(period())<=5;
  return <Row gap={20} style={{padding:20,borderWidth:1,borderColor:c().line,borderRadius:12}}>
    <View style={{width:52,height:52}}><Canvas style={{width:52,height:52}} draw={(cx)=>{cx.lineWidth=4;cx.strokeStyle=c().line;cx.beginPath();cx.arc(26,26,22,0,2*Math.PI);cx.stroke();cx.strokeStyle=low()?c().orange:c().blue;cx.beginPath();cx.arc(26,26,22,-Math.PI/2,-Math.PI/2+2*Math.PI*secondsLeft(period())/period());cx.stroke();}} /><View style={{position:"absolute",top:17,left:17}}><T mono size={12}>{secondsLeft(period())}</T></View></View>
    <View style={{flex:1}}><T mono size={p.large?40:24} color={low()?c().orange:c().ink}>{formatCode(code())||"——— ———"}</T><T mono size={12}>下一个 {formatCode(next())||"——— ———"}</T></View>
    <Btn label="复制验证码" disabled={!code()} onPress={()=>void copySecret(code(),"验证码")} /></Row>;
}
export function CodeSettings(p:EntryProps & { preview?: boolean }) {
  const uri=signal("");
  const apply=(fields:any)=>edit(p.item.id,d=>{for(const k of ["secret","period"])if(fields[k]!==undefined)d[k]=fields[k]; if(!d.username)d.username=fields.username; if(["未命名验证码","Untitled authenticator","未命名账号","Untitled account"].includes(d.title))d.title=fields.title; if(d.type==="totp")d.issuer=fields.issuer;});
  return <><SectionHead title="二次验证" /><If when={p.preview && p.item.secret}><View style={{marginBottom:10}}><CodePreview item={p.item} /></View></If><Group>
    <Field label="设置密钥" value={p.item.secret??""} secret editing={p.editing} onChange={v=>change(p.item,"secret")(normalizeSecret(v))} />
    <Field label="周期（秒）" value={String(p.item.period??30)} editing={p.editing} nocopy onChange={v=>{if(validPeriod(v))edit(p.item.id,d=>{d.period=Number(v);});}} />
    <If when={p.editing}><Field label="设置链接" value={uri()} secret editing onChange={v=>uri.set(v)} nocopy /><Row gap={8}><Btn label="导入链接" onPress={async()=>{try{apply(await parseCode(uri()));uri.set("");}catch(e){toast(errorText(e));}}} /><Btn label="图片导入…" onPress={()=>askAddCode(apply)} /><Btn label="清除验证码" kind="danger" onPress={()=>confirm({title:"清除二次验证设置？",text:"请先确认仍有其他登录方式。",ok:"确认清除",danger:true,onConfirm:()=>edit(p.item.id,d=>{d.secret="";d.period=30;})})} /></Row></If>
    <Row style={{paddingVertical:10}}><Btn label="复制设置链接" icon="link" disabled={!p.item.secret} onPress={()=>void copySecret(setupLink(p.item),"设置链接")} /></Row>
  </Group></>;
}
function showQR(item:Item) {
  confirm({title:"显示设置二维码？",text:"二维码包含完整密钥，任何看到它的人都能生成验证码。请确认周围没有他人或屏幕共享。",ok:"显示二维码",onConfirm:()=>{
    let rows:boolean[][];try{rows=JSON.parse(Relay.qr(setupLink(item)));}catch(e){toast(errorText(e));return;}
    openSheet({render:close=><><SheetTitle title="设置二维码" /><Canvas accessibilityLabel="验证码设置二维码" style={{width:280,height:280}} draw={(cx,size)=>{cx.fillStyle="#ffffff";cx.fillRect(0,0,size.width,size.height);const unit=Math.floor(280/rows.length);cx.fillStyle="#000000";rows.forEach((r,y)=>r.forEach((b,x)=>{if(b)cx.fillRect(x*unit,y*unit,unit,unit);}));}} /><Btn label="关闭" onPress={close} /></>});
  }});
}
export function CodeDetail(p:EntryProps) {
  const linked=()=>items().filter(i=>i.type==="password"&&!i.isDeleted&&p.item.secret&&normalizeSecret(i.secret??"")===normalizeSecret(p.item.secret));
  return <><EntryHero item={p.item} editing={p.editing&&!p.item.isDeleted} /><CodePreview item={p.item} large /><T color={c().muted}>最后 5 秒显示橙色。时间以本机时钟为准。</T>
    <SectionHead title="配置信息" /><Group><Field label="发行方" value={p.item.issuer??""} editing={p.editing} onChange={change(p.item,"issuer")} /><Field label="账号" value={p.item.username??""} editing={p.editing} onChange={change(p.item,"username")} /><Field label="算法" value="SHA1" nocopy /><Field label="位数" value="6 位" nocopy /></Group>
    <CodeSettings item={p.item} editing={p.editing&&!p.item.isDeleted} /><SectionHead title="关联账号" /><Each of={linked()}>{item=><Field label={item().title} value={item().username??""} actions={<Btn label="打开账号" onPress={()=>{dest.set("accounts");select(item().id);}} />}/>}</Each><If when={!linked().length}><T>未找到使用相同密钥的账号。</T></If>
    <SectionHead title="迁移" /><Row gap={8}><Btn label="显示设置二维码…" icon="qr" disabled={!p.item.secret} onPress={()=>showQR(p.item)} /><Btn label="重新导入…" icon="qr" disabled={!p.editing} onPress={()=>askAddCode((fields:any)=>edit(p.item.id,d=>{for(const k of ["secret","period"])if(fields[k]!==undefined)d[k]=fields[k];}))} /></Row><EntryMeta item={p.item} editing={p.editing&&!p.item.isDeleted} /></>;
}
