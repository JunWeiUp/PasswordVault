import { shortcutLabel } from "../shortcut-label";
import { openUrl } from "nsh";
import { Menu } from "nsh/desktop";
import { Banner, Btn, copySecret, Field, Group, Row, SectionHead, Strength, strengthOf, confirm, T } from "../kit";
import { audit, edit, generatePassword, toast, errorText } from "../store";
import { normalizeAccountIDs, newID, websites } from "./model";
import { CodeSettings } from "./CodeDetail";
import { EntryHero, EntryMeta, PasswordHistory, Passkeys, CustomFields, change, type EntryProps } from "./shared";
export function AccountDetail(p:EntryProps) {
  const openSite=(url:string)=>void openUrl(url).catch(()=>toast("无法打开该网址"));
  const openSites=()=>{const list=websites(p.item.url??"");if(list.length===1)openSite(list[0]);else void Menu.popup(list.map(url=>({label:url,onSelect:()=>openSite(url)})));};
  const editable=()=>p.editing&&!p.item.isDeleted;
  // Keep the pre-normalization credential available until the store has a baseline with IDs.
  const repaired = new Map<string, any>();
  const normalize=()=>edit(p.item.id,d=>{const old=d.accounts??[];d.accounts=normalizeAccountIDs(old);d.accounts.forEach((a:any,i:number)=>{if(a.id!==old[i].id)repaired.set(a.id,{...old[i]});});});
  const generate=async(index?:number)=>{try{
    const value=await generatePassword({length:24,upper:true,lower:true,digits:true,symbols:true});
    confirm({title:"使用新密码？",text:"请先在网站修改密码，再更新这里。",ok:"使用新密码",onConfirm:()=>{if(index===undefined)edit(p.item.id,d=>{d.password=value;});else accountChange(index,"password",value);}});
  }catch(e){toast(errorText(e));}};
  const accountChange=(index:number,key:string,value:string)=>{normalize();edit(p.item.id,d=>{d.accounts[index]={...d.accounts[index],[key]:value};
    const account=d.accounts[index], baseline=repaired.get(account.id);
    if(key==="password" && baseline && value!==(baseline.password??"")) {
      const at=new Date().toISOString();
      account.passwordHistory=[...(baseline.password?[{password:baseline.password,changedAt:at}]:[]),...(baseline.passwordHistory??[])];
      account.passwordLastChanged=at;
    }});};
  return <><EntryHero item={p.item} editing={editable()} />
    <If when={audit()[p.item.id]&&!p.item.isDeleted}><Banner tone="warn" title={audit()[p.item.id]?.weak?"密码过弱":audit()[p.item.id]?.reused?"密码被重复使用":"密码已超过设定的更换周期"} actions={<Btn label="生成新密码" onPress={()=>void generate()} />}>先在网站修改，再更新这里。</Banner></If>
    <Row gap={8} wrap style={{marginBottom:4}}><Btn label="复制密码" icon="copy" kind="primary" hint={shortcutLabel("⇧⌘C")}  disabled={!p.item.password} onPress={()=>void copySecret(p.item.password,"密码")} /><Btn label="复制用户名" hint={shortcutLabel("⌘C")}  disabled={!p.item.username} onPress={()=>void copySecret(p.item.username,"用户名")} /><If when={websites(p.item.url??"").length}><Btn label="打开网站" icon="globe" onPress={()=>openSites()} /></If></Row>
    <SectionHead title="登录信息" note={editable()?"修改即时加密保存":undefined} /><Group>
      <Field label="用户名" value={p.item.username??""} editing={editable()} onChange={change(p.item,"username")} />
      <Field label="密码" value={p.item.password??""} secret editing={editable()} onChange={change(p.item,"password")} after={<Strength level={strengthOf(p.item.password??"")} />} actions={<If when={editable()}><Btn label="生成" onPress={()=>void generate()} /></If>} />
      <PasswordHistory record={p.item} />
      <Field label="邮箱" value={p.item.email??""} editing={editable()} onChange={change(p.item,"email")} />
      <Field label="网站" value={p.item.url??""} editing={editable()} onChange={change(p.item,"url")} placeholder="多个网址用空格、逗号或分号分隔" actions={<If when={!editable()&&websites(p.item.url??"").length}><Btn kind="ghost" icon="globe" label={websites(p.item.url??"").length>1?"打开…":"打开"} onPress={()=>openSites()} /></If>} />
      <Field label="有效期（天）" value={!editable()&&!Number(p.item.passwordDuration??0)?"不限":String(p.item.passwordDuration??0)} editing={editable()} nocopy placeholder="0 为不限" onChange={v=>{if(/^\d+$/.test(v)&&Number.isSafeInteger(Number(v)))edit(p.item.id,d=>{d.passwordDuration=Number(v);});}} />
    </Group>
    <SectionHead title="附加账号" right={<If when={editable()}><Btn label="添加另一个账号" onPress={()=>edit(p.item.id,d=>{d.accounts=[...normalizeAccountIDs(d.accounts??[]),{id:newID(),label:"",username:"",password:""}];})} /></If>} />
    <Each of={(p.item.accounts??[]).map((_:any,index:number)=>index)}>{(index: () => number)=><Group>
      <Field label="用途" value={p.item.accounts[index()].label??""} editing={editable()} onChange={v=>accountChange(index(),"label",v)} />
      <Field label="附加用户名" value={p.item.accounts[index()].username??""} editing={editable()} onChange={v=>accountChange(index(),"username",v)} />
      <Field label="附加密码" value={p.item.accounts[index()].password??""} secret editing={editable()} onChange={v=>accountChange(index(),"password",v)} actions={<If when={editable()}><Btn label="生成附加密码" onPress={()=>void generate(index())} /></If>} />
      <PasswordHistory record={p.item.accounts[index()]} />
      <If when={editable()}><Row style={{paddingVertical:10}}><Btn label="移除附加账号" kind="danger" onPress={()=>{normalize();const id=p.item.accounts[index()].id;confirm({title:"移除此附加账号？",text:"该账号的用户名、密码及历史将从当前记录移除。",ok:"确认移除",danger:true,onConfirm:()=>edit(p.item.id,d=>{d.accounts=d.accounts.filter((a:any)=>a.id!==id);})});}} /></Row></If>
    </Group>}</Each>
    <If when={!(p.item.accounts??[]).length}><T size={11.5} color="#8490a2">同一网站的其他登录身份，例如测试账号或机器人账号。</T></If>
    <CodeSettings item={p.item} editing={editable()} preview />
    <Passkeys item={p.item} editing={editable()} /><CustomFields item={p.item} editing={editable()} /><EntryMeta item={p.item} editing={editable()} /></>;
}
