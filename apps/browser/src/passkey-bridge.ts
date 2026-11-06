import {validatePasskeyRequest} from "./passkey-request";
import type {Request} from "./core";
let epoch=0;
const pending=new Map<string,string>();
export function cancelPasskeys():void {epoch++;pending.clear();}
export async function handlePasskey(request:any,sender:chrome.runtime.MessageSender,core:(request:Request)=>Promise<any>):Promise<any>{
  if(sender.id!==chrome.runtime.id || sender.frameId!==0 || !sender.tab?.id || !sender.documentId || !sender.url)throw new Error("forbidden");
  if(request.action==="passkey-cancel"){pending.delete(sender.documentId);return {};}
  if(!["create","get"].includes(request.operation))throw new Error("invalid-request");
  if(pending.has(sender.documentId))throw new Error("busy");
  const tab=await chrome.tabs.get(sender.tab.id);
  if(!tab.url || tab.url!==sender.url)throw new Error("changed-origin");
  const validated=validatePasskeyRequest(request.operation,request.options,sender.url,tab.url);
  const id=crypto.randomUUID(), generation=epoch, started=Date.now();pending.set(sender.documentId,id);
  try {
    // Native host provides its own trusted approval and account picker for every ceremony.
    const result=await core({op:request.operation==="create"?"passkey-create":"passkey-assert",origin:new URL(sender.url).origin,rpId:validated.rpId,userHandle:validated.user?.id,userName:validated.user?.name,clientDataJSON:validated.clientDataJSON,excluded:validated.excludeCredentials,allowed:validated.allowCredentials});
    const current=await chrome.tabs.get(sender.tab.id);
    if(epoch!==generation || pending.get(sender.documentId)!==id || current.url!==sender.url || Date.now()-started>=60000)throw new Error("expired");
    const ack=await chrome.tabs.sendMessage(sender.tab.id,{action:"passkey-document-check"},{documentId:sender.documentId});
    if(!ack?.ok || epoch!==generation || pending.get(sender.documentId)!==id)throw new Error("expired");
    return result;
  } finally {if(pending.get(sender.documentId)===id)pending.delete(sender.documentId);}
}
