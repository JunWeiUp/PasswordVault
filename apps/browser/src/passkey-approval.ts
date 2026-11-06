import type {Request} from "./core";
type Approval={scope:string;id:string;request:Request;expires:number;resolve:(value:any)=>void;reject:(error:Error)=>void;timer:ReturnType<typeof setTimeout>;core:(request:Request)=>Promise<any>};
let active:Approval|undefined;
export function cancelPasskeyApproval(scope?:string){if(scope && active?.scope!==scope)return;const old=active;active=undefined;if(old){clearTimeout(old.timer);old.reject(new Error("cancelled"));}}
export function requestPasskeyApproval(request:Request,core:(request:Request)=>Promise<any>,scope:string):Promise<any>{
  if(active)throw new Error("busy");
  return new Promise((resolve,reject)=>{
    const id=crypto.randomUUID();
    active={scope,id,request,resolve,reject,expires:Date.now()+60000,core,timer:setTimeout(()=>cancelPasskeyApproval(scope),60000)};
    void chrome.action.setBadgeText({text:"KEY"});
    void chrome.action.openPopup().catch(()=>{});
  });
}
export async function passkeyApproval(action:string,args:any):Promise<any>{
  const value=active;
  if(action==="passkey-pending"){
    if(!value)return null;
    const matches=value.request.op==="passkey-assert"?await value.core({op:"passkey-matches",rpId:value.request.rpId}):[];
    if(value!==active)return null;
    const allowed=value.request.allowed as string[];
    return {id:value.id,operation:value.request.op,origin:value.request.origin,userName:value.request.userName,expires:value.expires,matches:matches.filter((m:any)=>!allowed?.length || allowed.includes(m.id))};
  }
  if(!value || value.id!==args.id || value.expires<=Date.now())throw new Error("expired");
  if(action==="passkey-reject"){cancelPasskeyApproval();return {};}
  if(action!=="passkey-approve" || typeof args.currentPassword!=="string")throw new Error("invalid-request");
  try {
    const result=await value.core({...value.request,itemId:args.itemId,credentialId:args.credentialId,library:args.library,currentPassword:args.currentPassword});
    if(value!==active)throw new Error("cancelled");
    clearTimeout(value.timer);active=undefined;value.resolve(result);
    void chrome.action.setBadgeText({text:""});return {};
  } catch(error){if(value===active){cancelPasskeyApproval();}throw error;}
}
