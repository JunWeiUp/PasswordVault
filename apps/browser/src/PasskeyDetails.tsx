import {useState} from "preact/hooks";
import {command,errorText} from "./client";
import {t,useLocale} from "./i18n";
export function PasskeyDetails({item,refresh,editable=true}:{item:any;refresh:()=>Promise<void>;editable?:boolean}){
 useLocale();const[selected,setSelected]=useState<string>();const[secret,setSecret]=useState("");const[busy,setBusy]=useState(false);const[error,setError]=useState("");
 if(!Array.isArray(item.passkeys)||!item.passkeys.length)return null;
 return <section><h3>Passkeys</h3>{item.passkeys.map((key:any)=><article key={key.credentialId}><strong>{key.rpId}</strong><p>{key.userName}</p><small>{key.credentialId}</small><button disabled={busy||!editable} onClick={()=>{setSelected(key.credentialId);setSecret("");setError("");}}>{t("删除此通行密钥")}</button></article>)}{selected&&<form onSubmit={async e=>{e.preventDefault();if(!editable)return;if(!confirm(t("删除后此凭证将不再可用于登录，网站上的注册记录不会自动删除。")))return;setBusy(true);try{await command({op:"passkey-remove",itemId:item.id,credentialId:selected,currentPassword:secret});setSelected(undefined);await refresh();}catch(err){setError(t(errorText(err)));}finally{setSecret("");setBusy(false);}}}><p>{t("重新输入主密码以确认删除")}</p><input type="password" autoComplete="off" value={secret} onInput={e=>setSecret(e.currentTarget.value)}/>{error&&<p role="alert">{error}</p>}<button disabled={busy||!secret||!editable}>{t("确认删除")}</button><button type="button" onClick={()=>{setSecret("");setSelected(undefined);}}>{t("取消")}</button></form>}</section>;
}
