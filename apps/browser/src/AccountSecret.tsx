import { t, fmt } from "./i18n";
import { useEffect, useRef, useState } from "preact/hooks";
import { errorText, message } from "./client";

export function AccountSecret({ account, origin, tabId, disabled }: {
  account: {id:string;accountId?:string;title:string;username:string};
  origin: string; tabId:number; disabled:boolean;
}) {
  const [secret,setSecret]=useState<string>();
  const [busy,setBusy]=useState(false);
  const [copied,setCopied]=useState(false);
  const [error,setError]=useState("");
  const generation=useRef(0);
  const hide=()=>{generation.current++;setSecret(undefined);setBusy(false);setCopied(false);};
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
  useEffect(()=>{
    if(!copied)return;
    const timer=setTimeout(()=>setCopied(false),2000);
    return()=>clearTimeout(timer);
  },[copied]);
  async function reveal(){
    if(secret!==undefined){hide();return;}
    const epoch=++generation.current;setBusy(true);setError("");
    let value: {password?:string}|undefined;
    try{
      value=await message({action:"reveal-account",tabId,origin,id:account.id,accountId:account.accountId});
      if(epoch===generation.current && !document.hidden)setSecret(value?.password??"");
    }catch(e){if(epoch===generation.current)setError(t(errorText(e)));}
    finally{if(value)value.password="";if(epoch===generation.current)setBusy(false);}
  }
  async function copyPassword(){
    const epoch=++generation.current;setBusy(true);setError("");
    let value: {password?:string}|undefined;
    try{
      value=await message({action:"reveal-account",tabId,origin,id:account.id,accountId:account.accountId});
      const text=value?.password??"";
      if(epoch===generation.current && text){
        await navigator.clipboard.writeText(text);
        setCopied(true);
      }
    }catch(e){if(epoch===generation.current)setError(t(errorText(e)));}
    finally{if(value)value.password="";if(epoch===generation.current)setBusy(false);}
  }
  return <div class="account-secret">
    <code aria-label={t("密码")}>{secret??"••••••••"}</code>
    <button type="button" class="text-button" disabled={disabled||busy}
      aria-label={fmt(t("复制密码：{title} {username}"),{title:account.title,username:account.username})}
      onClick={()=>void copyPassword()}>{copied?t("已复制"):t("复制密码")}</button>
    <button type="button" class="text-button" disabled={disabled||busy}
      aria-label={fmt(secret===undefined?t("显示密码：{title} {username}"):t("隐藏密码：{title} {username}"),{title:account.title,username:account.username})}
      onClick={()=>void reveal()}>{busy?t("读取中…"):secret===undefined?t("显示密码"):t("隐藏密码")}</button>
    {error&&<small role="alert">{error}</small>}
  </div>;
}
