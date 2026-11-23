import { t, fmt } from "./i18n";
import {useState} from "preact/hooks";
import {message,errorText} from "./client";
// Payment cards and identities fill HTTPS pages only (enforced again in the background);
// the security code is opt-in per fill, and every fill is confirmed in the popup.
export function StructuredFill(){
 const[state,setState]=useState<any>();const[selected,setSelected]=useState("");const[security,setSecurity]=useState(false);const[error,setError]=useState("");const[busy,setBusy]=useState(false);const[confirming,setConfirming]=useState(false);
 const list=async()=>{setBusy(true);setError("");setConfirming(false);try{setState(await message({action:"structured-list"}));setSelected("");setSecurity(false);}catch(e){setError(t(errorText(e)));}finally{setBusy(false);}};
 const fill=async()=>{setBusy(true);try{await message({action:"structured-fill",id:selected,includeSecurityCode:security,origin:state.origin,tabId:state.tabId});setState(undefined);setSecurity(false);}catch(e){setError(t(errorText(e)));}finally{setConfirming(false);setBusy(false);}};
 const item=state?.items.find((entry:any)=>entry.id===selected);
 return <section class="card">
  <button disabled={busy} onClick={()=>void list()}>{t("选择银行卡 / 身份资料填充")}</button>
  {state&&<>
   <p>{t("仅填入 HTTPS 页面：")}{state.origin}</p>
   {state.items.length <= 6 ? (
    <div class="pick-cards" role="radiogroup" aria-label={t("选择资料")}>
     {state.items.map((entry:any)=>{
      const active=selected===entry.id;
      return <button type="button" role="radio" aria-checked={active} class={`pick-card${active?" on":""}`} disabled={confirming} onClick={()=>{setSelected(entry.id);setSecurity(false);}}>
       <span class="dot"/><span><b>{entry.title}</b><small>{entry.type==="creditCard"?t("银行卡"):t("身份资料")}</small></span>
      </button>;
     })}
    </div>
   ) : (
    <select value={selected} disabled={confirming} onChange={e=>{setSelected(e.currentTarget.value);setSecurity(false);}}><option value="">{t("选择资料")}</option>{state.items.map((entry:any)=><option value={entry.id}>{entry.title} · {entry.type==="creditCard"?t("银行卡"):t("身份资料")}</option>)}</select>
   )}
   {item?.type==="creditCard"&&<label><input type="checkbox" checked={security} disabled={confirming} onChange={e=>setSecurity(e.currentTarget.checked)}/>{t("本次也填入安全码")}</label>}
   {confirming&&item?<div class="confirm-card" role="alertdialog" aria-label={t("确认填入所选资料")}>
     <p>{fmt(t("确认将所选资料填入 {origin}？网页可以读取已填入的内容。"),{origin:state.origin})}</p>
     {item.type==="creditCard"&&<p>{security?t("将同时填入安全码。"):t("不会填入安全码。")}</p>}
     <div class="actions"><button type="button" disabled={busy} onClick={()=>setConfirming(false)}>{t("取消")}</button><button type="button" class="primary" disabled={busy} onClick={()=>void fill()}>{t("填入")}</button></div>
   </div>:<button disabled={busy||!selected} onClick={()=>setConfirming(true)}>{t("确认填入所选资料")}</button>}
  </>}
  {error&&<p class="error" role="alert">{error}</p>}
 </section>;
}
