import { signal, View } from "nsh";
import { Menu } from "nsh/desktop";
import { Btn, Field, Group, Row, SectionHead, T, TextBox, openSheet, SheetTitle, SheetFooter } from "../kit";
import { edit, call, load, flush, errorText, type Item } from "../store";
import { openItemHistory } from "../history";
import { colors, newID, websites } from "./model";
import { Tile } from "../ItemList";
export type EntryProps = { item: Item; editing: boolean };
export const change = (item: Item, key: string) => (value: string) => edit(item.id, d => { d[key] = value; });
export function EntryHero(p: EntryProps) {
  const sub = () =>
    p.item.type === "totp"
      ? [p.item.issuer, p.item.username].filter(Boolean).join(" · ")
      : [websites(p.item.url ?? "")[0], p.item.category, ...(p.item.tags ?? []).map((t: string) => `#${t}`)].filter(Boolean).join(" · ");
  return (
    <Row gap={16} style={{ marginBottom: 18 }}>
      <Tile item={p.item} size={60} />
      <View style={{ flex: 1, minWidth: 0, gap: 4 }}>
        <If when={p.editing} else={<T size={26} weight="600" lines={2} selectable>{p.item.title || "未命名"}</T>}>
          <TextBox label="标题" value={p.item.title} onChange={change(p.item, "title")} />
        </If>
        <T size={12} color="#8490a2" lines={1}>{sub()}</T>
      </View>
    </Row>
  );
}
export function PasswordHistory(p: { record: any }) {
  return <Field label="密码历史" value={`${p.record.passwordHistory?.length ?? 0} 个旧密码`} nocopy actions={<Btn label="查看历史" kind="ghost" onPress={() => openSheet({render: close => <><SheetTitle title="密码历史" /><Each of={p.record.passwordHistory ?? []}>{(h: any) => <Field label={h().changedAt ?? "旧密码"} value={h().password ?? ""} secret />}</Each><Btn label="关闭" onPress={close} /></>})} />}/>;
}
export function EntryMeta(p: EntryProps) {
  return <><SectionHead title="备注" /><Field label="备注" value={p.item.note ?? ""} multiline editing={p.editing} onChange={change(p.item,"note")} nocopy />
    <SectionHead title="记录" /><Group>
    <Field label="分类" value={p.item.category ?? ""} editing={p.editing} onChange={change(p.item,"category")} nocopy />
    <Field label="标签" value={(p.item.tags ?? []).join("、")} editing={p.editing} onChange={v => edit(p.item.id,d => { d.tags=v.split(/[、,，]/).map(s=>s.trim()).filter(Boolean); })} nocopy />
    <Field label="颜色标记" value={p.item.colorLabel || "无"} nocopy actions={<If when={p.editing}><Btn label="选择颜色" onPress={() => void Menu.popup(colors.map(value=>({label:value || "无",checked:p.item.colorLabel===value,onSelect:()=>edit(p.item.id,d=>{d.colorLabel=value;})})))} /></If>} />
    <Field label="修改时间" value={p.item.updatedAt ?? ""} nocopy />
    <Field label="版本历史" value="加密版本记录" nocopy actions={<Btn label="打开版本历史" onPress={()=>openItemHistory(p.item)} />} />
    </Group></>;
}
export function CustomFields(p: EntryProps) {
  const update = (index: number,key:string,value:string) => edit(p.item.id,d=>{d.customFields[index]={...d.customFields[index],[key]:value};});
  return <><SectionHead title="自定义字段" right={<If when={p.editing}><Btn label="添加字段" disabled={(p.item.customFields?.length ?? 0)>=256} onPress={()=>edit(p.item.id,d=>{d.customFields=[...(d.customFields??[]),{id:newID(),label:"",kind:"concealed",value:""}];})} /></If>} />
    <Each of={(p.item.customFields ?? []).map((_:any,i:number)=>i)}>{(index: () => number)=><Group>
      <Field label="字段名称" value={p.item.customFields[index()].label??""} editing={p.editing} onChange={v=>update(index(),"label",v)} />
      <Field label="分组" value={p.item.customFields[index()].group??""} editing={p.editing} onChange={v=>update(index(),"group",v)} />
      <Field label="类型" value={p.item.customFields[index()].kind??"text"} nocopy actions={<If when={p.editing}><Btn label="选择类型" onPress={()=>void Menu.popup(["text","concealed","url","email","date"].map(kind=>({label:kind,onSelect:()=>update(index(),"kind",kind)})))} /></If>} />
      <Each of={[p.item.customFields[index()].kind]} key={k=>k}>{()=> <Field label="内容" value={p.item.customFields[index()].value??""} secret={p.item.customFields[index()].kind==="concealed"} editing={p.editing} onChange={v=>update(index(),"value",v)} />}</Each>
      <If when={p.editing}><Btn label="移除字段" kind="danger" onPress={()=>edit(p.item.id,d=>{d.customFields.splice(index(),1);})} /></If>
    </Group>}</Each></>;
}
export function Passkeys(p: EntryProps) {
  const remove = (credentialId:string) => {
    const password=signal(""), error=signal(""), busy=signal(false);
    openSheet({render:close=><><SheetTitle title="删除此通行密钥？" text="请确认网站仍有其他登录方式；网站注册不会自动撤销。" />
      <TextBox label="当前主密码" masked value={password()} onChange={v=>password.set(v)} /><T>{error()}</T>
      <SheetFooter><Btn label="取消" disabled={busy()} onPress={()=>{password.set("");close();}} /><Btn label="确认删除" kind="danger" disabled={busy()||!password()} onPress={async()=>{busy.set(true);try {if (!(await flush())) throw new Error("请先保存当前修改后重试。");await call({op:"passkey-remove",itemId:p.item.id,credentialId,currentPassword:password()});await load();close();}catch(e){error.set(errorText(e));}finally{password.set("");busy.set(false);}}} /></SheetFooter></>});
  };
  return <If when={p.item.passkeys?.length}><SectionHead title="通行密钥" /><Each of={p.item.passkeys??[]}>{(key:any)=><Group><Field label="网站" value={key().rpId??""} /><Field label="用户" value={key().userName??""} /><Field label="创建时间" value={key().createdAt??"未记录"} nocopy /><If when={p.editing}><Btn label="删除通行密钥…" kind="danger" onPress={()=>remove(key().credentialId)} /></If></Group>}</Each></If>;
}
