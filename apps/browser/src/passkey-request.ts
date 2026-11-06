/** Inputs accepted only from a browser-bound document, never trust the page's origin. */
export type PasskeyRequest = {
  operation: "create" | "get";
  rpId: string;
  challenge: string;
  user?: { id: string; name: string };
  allowCredentials: string[];
  excludeCredentials: string[];
  clientDataJSON: string;
};
function decode(value: unknown, min: number, max: number): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid-request");
  const bytes = atob(value.replace(/-/g,"+").replace(/_/g,"/"));
  if (bytes.length < min || bytes.length > max || btoa(bytes).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"") !== value) throw new Error("invalid-request");
  return value;
}
export function validatePasskeyRequest(operation: "create" | "get", options: any, documentURL: string, topURL: string): PasskeyRequest {
  const source = new URL(documentURL), top = new URL(topURL);
  if (source.protocol !== "https:" || source.origin !== top.origin) throw new Error("invalid-origin");
  const rpId = (operation === "create" ? options?.rp?.id : options?.rpId) ?? source.hostname;
  // Core performs authoritative PSL validation; here require a DNS-label suffix.
  if (typeof rpId !== "string" || (rpId !== source.hostname && !source.hostname.endsWith("." + rpId)) || !rpId.includes(".")) throw new Error("unsupported-rp");
  const verification = operation === "create" ? options?.authenticatorSelection?.userVerification : options?.userVerification;
  if (verification !== undefined && !["required", "preferred", "discouraged"].includes(verification)) throw new Error("invalid-request");
  if (options?.extensions && Object.keys(options.extensions).length) throw new Error("native-fallback");
  if (operation === "create" && (!options?.pubKeyCredParams?.some((p: any) => p.type === "public-key" && p.alg === -7) || (options?.attestation && options.attestation !== "none"))) throw new Error("native-fallback");
  const challenge = decode(options?.challenge,16,1024);
  const list = (input: unknown): string[] => {
    if (input === undefined) return [];
    if (!Array.isArray(input) || input.length > 64) throw new Error("invalid-request");
    return input.map((c) => { if (c.type !== "public-key") throw new Error("invalid-request"); return decode(c.id,1,1024); });
  };
  let user: PasskeyRequest["user"];
  if (operation === "create") {
    if (typeof options?.user?.name !== "string" || options.user.name.length > 1024) throw new Error("invalid-request");
    user = {id:decode(options.user.id,1,64),name:options.user.name};
  }
  return {operation,rpId,challenge,user,allowCredentials:list(options?.allowCredentials),excludeCredentials:list(options?.excludeCredentials),clientDataJSON:JSON.stringify({type:`webauthn.${operation}`,origin:source.origin,challenge,crossOrigin:false})};
}
/** One-shot request lifecycle. UI may resolve only a current document's own request. */
export class PasskeyRequests {
  private requests = new Map<string,{documentId:string;url:string;expires:number;request:PasskeyRequest}>();
  add(documentId:string,url:string,request:PasskeyRequest,now=Date.now()):string {
    this.cancelDocument(documentId);
    for(const [id,r] of this.requests) if(r.expires<=now)this.requests.delete(id);
    if(this.requests.size>=32)throw new Error("busy");
    const id=crypto.randomUUID(); this.requests.set(id,{documentId,url,request,expires:now+60_000}); return id;
  }
  take(id:string,documentId:string,url:string,now=Date.now()):PasskeyRequest {
    const value=this.requests.get(id); this.requests.delete(id);
    if(!value || value.documentId!==documentId || value.url!==url || value.expires<=now)throw new Error("expired");
    return value.request;
  }
  cancelDocument(documentId:string):void { for(const[id,value]of this.requests)if(value.documentId===documentId)this.requests.delete(id); }
  clear():void { this.requests.clear(); }
}
