import { useEffect, useRef, useState } from "preact/hooks";
import { errorText, message } from "./client";

export function AccountSecret({ account, origin, tabId, disabled }: {
  account: {id:string;accountId?:string;title:string;username:string};
  origin: string; tabId:number; disabled:boolean;
}) {
  const [secret,setSecret]=useState<string>();
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState("");
  const generation=useRef(0);
  const hide=()=>{generation.current++;setSecret(undefined);setBusy(false);};
  useEffect(()=>{
    const conceal=()=>hide();
    window.addEventListener("blur",conceal);
    document.addEventListener("visibilitychange",conceal);
    return ()=>{generation.current++;window.removeEventListener("blur",conceal);document.removeEventListener("visibilitychange",conceal);};
  },[]);
  useEffect(()=>{hide();setError("");},[origin,tabId,account.id,account.accountId,account.username,disabled]);
  useEffect(()=>{
    if(secret===undefined)return;
    const timer=setTimeout(hide,30000);
    return()=>clearTimeout(timer);
  },[secret]);
  async function reveal(){
    if(secret!==undefined){hide();return;}
    const epoch=++generation.current;setBusy(true);setError("");
    let value: {password?:string}|undefined;
    try{
      value=await message({action:"reveal-account",tabId,origin,id:account.id,accountId:account.accountId});
      if(epoch===generation.current && !document.hidden)setSecret(value?.password??"");
    }catch(e){if(epoch===generation.current)setError(errorText(e));}
    finally{if(value)value.password="";if(epoch===generation.current)setBusy(false);}
  }
  return <div class="account-secret">
    <code aria-label="密码">{secret??"••••••••"}</code>
    <button type="button" class="text-button" disabled={disabled||busy}
      aria-label={`${secret===undefined?"显示":"隐藏"}密码：${account.title} ${account.username}`}
      onClick={()=>void reveal()}>{busy?"读取中…":secret===undefined?"显示密码":"隐藏密码"}</button>
    {error&&<small role="alert">{error}</small>}
  </div>;
}
