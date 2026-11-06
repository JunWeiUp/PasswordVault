import { mount, signal, View, Scroll } from "nsh";
import { AccountDetail } from "./AccountDetail";
import { CodeDetail, askAddCode } from "./CodeDetail";
import { Btn, SheetHost, T } from "../kit";
import { items, unlock, createItem, edit, flush, load } from "../store";
const ready=signal(false), mode=signal("account"), error=signal("");
const item=()=>items().find(i=>i.id==="entries-fixture");
mount(()=> <View style={{flex:1}}><Btn label="准备测试库" onPress={async()=>{try{await unlock("synthetic-preview-password");await createItem("password",{id:"entries-fixture",title:"Example",username:"qa",password:"before",secret:"JBSWY3DPEHPK3PXP"});ready.set(true);}catch(e){error.set(String(e));}}} /><T>{error()}</T><T>{`验证码数量 ${items().filter(i=>i.type==="totp").length}`}</T>
<If when={ready()}><RowButtons /><T>{item()?.colorLabel??"无颜色"}</T><T>{item()?.accounts?.[0]?.username==="qa-extra" && item()?.accounts?.[0]?.label==="测试用途" ? "附加已保存" : ""}</T><T>{`附加数量 ${item()?.accounts?.length??0}`}</T>
<Scroll style={{flex:1}}><Each of={[mode()]} key={v=>v}>{()=> <If when={mode()==="account"} else={<CodeDetail item={item()!} editing />}><AccountDetail item={item()!} editing /></If>}</Each></Scroll></If><SheetHost /></View>);
function RowButtons(){return <><Btn label="验证码视图" onPress={()=>mode.set("code")} /><Btn label="新增验证码" onPress={()=>askAddCode()} /><Btn label="保存并重读" onPress={async()=>{await flush();await load();}} /></>;}
