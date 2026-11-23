// MAIN-world WebAuthn adaptation. All authorization happens outside this world.
(() => {
  if (window !== top || location.protocol !== "https:" || !navigator.credentials) return;
  const encode=(value:ArrayBuffer|ArrayBufferView) => {
    const bytes=value instanceof ArrayBuffer?new Uint8Array(value):new Uint8Array(value.buffer,value.byteOffset,value.byteLength);
    let raw=""; for(const byte of bytes)raw+=String.fromCharCode(byte);
    return btoa(raw).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
  };
  const decode=(value:string):ArrayBuffer => Uint8Array.from(atob(value.replace(/-/g,"+").replace(/_/g,"/")),c=>c.charCodeAt(0)).buffer;
  // A user decision or an existing registration is final; other failures hand over to the browser.
  const refusal=(error:unknown):string|undefined=>({cancelled:"NotAllowedError",authentication:"NotAllowedError",expired:"NotAllowedError","already-registered":"InvalidStateError","Vault already exists":"InvalidStateError"} as Record<string,string>)[String(error)];
  // Extensions this authenticator implements; appid/appidExclude only concern legacy U2F keys it never holds.
  const SUPPORTED=new Set(["prf","credProps","appid","appidExclude"]);
  const originalCreate=navigator.credentials.create.bind(navigator.credentials);
  const originalGet=navigator.credentials.get.bind(navigator.credentials);
  const bin=(value:unknown)=>value instanceof ArrayBuffer||ArrayBuffer.isView(value);
  const prfInputs=(value:any)=>bin(value?.first)?{first:encode(value.first),...(bin(value.second)?{second:encode(value.second)}:{})}:undefined;
  /** Public extension inputs only; undefined means "unsupported, use the browser". */
  function extensionInputs(extensions:any):Record<string,unknown>|undefined {
    if(!extensions)return {};
    if(Object.keys(extensions).some(name=>!SUPPORTED.has(name)))return undefined;
    const out:Record<string,unknown>={};
    if(extensions.credProps===true)out.credProps=true;
    if(extensions.prf){
      out.prf=prfInputs(extensions.prf.eval)??{};
      if(extensions.prf.evalByCredential && typeof extensions.prf.evalByCredential==="object"){
        const by:Record<string,unknown>={};
        for(const [id,value] of Object.entries(extensions.prf.evalByCredential)){const inputs=prfInputs(value);if(!inputs)return undefined;by[id]=inputs;}
        out.prfByCredential=by;
      }
    }
    return out;
  }
  function credential(operation:"create"|"get",r:any,inputs:Record<string,unknown>):Credential {
    const response:any={clientDataJSON:decode(r.clientDataJson)};
    if(operation==="create") {
      response.attestationObject=decode(r.attestationObject);
      response.getTransports=()=>["internal"];
      response.getAuthenticatorData=()=>decode(r.authenticatorData);
      response.getPublicKeyAlgorithm=()=>-7;
      response.getPublicKey=()=>r.publicKey?decode(r.publicKey):null;
      Object.setPrototypeOf(response,AuthenticatorAttestationResponse.prototype);
    } else {
      response.authenticatorData=decode(r.authenticatorData);response.signature=decode(r.signature);response.userHandle=decode(r.userHandle);
      Object.setPrototypeOf(response,AuthenticatorAssertionResponse.prototype);
    }
    // Client extension outputs: binary for getClientExtensionResults, base64url for toJSON.
    const results=(json:boolean)=>{
      const out:any={};
      if(inputs.credProps && operation==="create")out.credProps={rk:true};
      if(inputs.prf && r.prf){
        out.prf={};
        if(operation==="create")out.prf.enabled=r.prf.enabled===true;
        if(r.prf.results?.first)out.prf.results={first:json?r.prf.results.first:decode(r.prf.results.first),...(r.prf.results.second?{second:json?r.prf.results.second:decode(r.prf.results.second)}:{})};
      }
      return out;
    };
    const result:any={id:r.id,rawId:decode(r.id),type:"public-key",authenticatorAttachment:"platform",response,getClientExtensionResults:()=>results(false),toJSON:()=>({id:r.id,rawId:r.id,type:"public-key",authenticatorAttachment:"platform",clientExtensionResults:results(true),response:operation==="create"?{clientDataJSON:r.clientDataJson,attestationObject:r.attestationObject,transports:["internal"],publicKeyAlgorithm:-7,publicKey:r.publicKey,authenticatorData:r.authenticatorData}:{clientDataJSON:r.clientDataJson,authenticatorData:r.authenticatorData,signature:r.signature,userHandle:r.userHandle}})};
    Object.setPrototypeOf(result,PublicKeyCredential.prototype);
    return result;
  }
  function publicRequest(key:any,inputs:Record<string,unknown>){
    const request={...key,extensions:undefined,...inputs,challenge:encode(key.challenge),allowCredentials:key.allowCredentials?.map((c:any)=>({...c,id:encode(c.id)})),excludeCredentials:key.excludeCredentials?.map((c:any)=>({...c,id:encode(c.id)}))};
    if(key.user)request.user={...key.user,id:encode(key.user.id)};
    return request;
  }
  async function ceremony(operation:"create"|"get", options:any):Promise<Credential|null> {
    const original=operation==="create"?originalCreate:originalGet;
    const key=options?.publicKey;
    const inputs=key?extensionInputs(key.extensions):undefined;
    if (key && inputs && options.mediation==="conditional" && operation==="get") return conditional(options,key,inputs);
    if (!key || !inputs || options.mediation==="conditional" || (operation==="create" && (!key.pubKeyCredParams?.some((p:any)=>p.alg===-7 && p.type==="public-key") || (key.attestation && key.attestation!=="none")))) return original(options);
    if(options.signal?.aborted)throw new DOMException("Aborted","AbortError");
    const request=publicRequest(key,inputs);
    const id=crypto.randomUUID();
    return new Promise((resolve,reject)=>{
      const cleanup=()=>{clearTimeout(timer);window.removeEventListener("message",receive);options.signal?.removeEventListener("abort",abort);};
      const abort=()=>{window.postMessage({channel:"pv-passkey-cancel",id},location.origin);cleanup();reject(new DOMException("Aborted","AbortError"));};
      const receive=(event:MessageEvent)=>{
        if(event.source!==window || event.origin!==location.origin || event.data?.channel!=="pv-passkey-response" || event.data.id!==id)return;
        cleanup();
        const reply=event.data.result;
        if(!reply?.ok){
          const final=refusal(reply?.error);
          if(final){ reject(new DOMException(final==="InvalidStateError"?"Credential already registered":"Not allowed",final)); return; }
          void original(options).then(resolve,reject); return;
        }
        resolve(credential(operation,reply.data,inputs));
      };
      const timer=setTimeout(()=>{cleanup();reject(new DOMException("Timed out","NotAllowedError"));},Math.min(Math.max(key.timeout??60000,1000),60000));
      options.signal?.addEventListener("abort",abort,{once:true});window.addEventListener("message",receive);
      window.postMessage({channel:"pv-passkey-request",id,operation,options:request},location.origin);
    });
  }
  // Conditional mediation: the browser's own autofill stays active while the extension menu offers
  // "use a passkey". Whichever completes first wins; the other is cancelled.
  function conditional(options:any,key:any,inputs:Record<string,unknown>):Promise<Credential|null> {
    if(options.signal?.aborted)return Promise.reject(new DOMException("Aborted","AbortError"));
    const controller=new AbortController();
    const id=crypto.randomUUID();
    return new Promise((resolve,reject)=>{
      let settled=false;
      const finish=(fn:()=>void)=>{ if(settled)return; settled=true; window.removeEventListener("message",receive); options.signal?.removeEventListener("abort",abort); fn(); };
      const abort=()=>finish(()=>{controller.abort();window.postMessage({channel:"pv-passkey-cancel",id},location.origin);reject(new DOMException("Aborted","AbortError"));});
      const receive=(event:MessageEvent)=>{
        // Failed or cancelled attempts keep the request open so the user can choose again.
        if(event.source!==window || event.origin!==location.origin || event.data?.channel!=="pv-passkey-response" || event.data.id!==id || !event.data.result?.ok)return;
        const value=credential("get",event.data.result.data,inputs);
        finish(()=>{controller.abort();resolve(value);});
      };
      options.signal?.addEventListener("abort",abort,{once:true});window.addEventListener("message",receive);
      originalGet({...options,signal:controller.signal}).then(
        value=>finish(()=>{window.postMessage({channel:"pv-passkey-cancel",id},location.origin);resolve(value);}),
        // Only the page's own abort ends the request; a browser-side failure leaves our option available.
        ()=>{ if(options.signal?.aborted)abort(); });
      window.postMessage({channel:"pv-passkey-request",id,operation:"get",options:publicRequest(key,inputs),conditional:true},location.origin);
    });
  }
  navigator.credentials.create=(options)=>ceremony("create",options);
  navigator.credentials.get=(options)=>ceremony("get",options);
})();
