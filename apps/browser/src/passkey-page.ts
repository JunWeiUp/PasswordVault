// MAIN-world WebAuthn adaptation. All authorization happens outside this world.
(() => {
  if (window !== top || location.protocol !== "https:" || !navigator.credentials) return;
  const encode=(value:ArrayBuffer|ArrayBufferView) => {
    const bytes=value instanceof ArrayBuffer?new Uint8Array(value):new Uint8Array(value.buffer,value.byteOffset,value.byteLength);
    let raw=""; for(const byte of bytes)raw+=String.fromCharCode(byte);
    return btoa(raw).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
  };
  const decode=(value:string):ArrayBuffer => Uint8Array.from(atob(value.replace(/-/g,"+").replace(/_/g,"/")),c=>c.charCodeAt(0)).buffer;
  const originalCreate=navigator.credentials.create.bind(navigator.credentials);
  const originalGet=navigator.credentials.get.bind(navigator.credentials);
  async function ceremony(operation:"create"|"get", options:any):Promise<Credential|null> {
    const original=operation==="create"?originalCreate:originalGet;
    const key=options?.publicKey;
    const uv=operation==="create"?key?.authenticatorSelection?.userVerification:key?.userVerification;
    if (!key || options.mediation==="conditional" || (key.extensions && Object.keys(key.extensions).length) || (operation==="create" && (!key.pubKeyCredParams?.some((p:any)=>p.alg===-7 && p.type==="public-key") || (key.attestation && key.attestation!=="none")))) return original(options);
    if(options.signal?.aborted)throw new DOMException("Aborted","AbortError");
    const request={...key,challenge:encode(key.challenge),allowCredentials:key.allowCredentials?.map((c:any)=>({...c,id:encode(c.id)})),excludeCredentials:key.excludeCredentials?.map((c:any)=>({...c,id:encode(c.id)}))};
    if(key.user)request.user={...key.user,id:encode(key.user.id)};
    const id=crypto.randomUUID();
    return new Promise((resolve,reject)=>{
      const cleanup=()=>{clearTimeout(timer);window.removeEventListener("message",receive);options.signal?.removeEventListener("abort",abort);};
      const abort=()=>{window.postMessage({channel:"pv-passkey-cancel",id},location.origin);cleanup();reject(new DOMException("Aborted","AbortError"));};
      const receive=(event:MessageEvent)=>{
        if(event.source!==window || event.origin!==location.origin || event.data?.channel!=="pv-passkey-response" || event.data.id!==id)return;
        cleanup();
        const reply=event.data.result;
        if(!reply?.ok){ void original(options).then(resolve,reject); return; }
        const r=reply.data;
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
        const result:any={id:r.id,rawId:decode(r.id),type:"public-key",authenticatorAttachment:"platform",response,getClientExtensionResults:()=>({}),toJSON:()=>({id:r.id,rawId:r.id,type:"public-key",authenticatorAttachment:"platform",clientExtensionResults:{},response:operation==="create"?{clientDataJSON:r.clientDataJson,attestationObject:r.attestationObject,transports:["internal"],publicKeyAlgorithm:-7,publicKey:r.publicKey,authenticatorData:r.authenticatorData}:{clientDataJSON:r.clientDataJson,authenticatorData:r.authenticatorData,signature:r.signature,userHandle:r.userHandle}})};
        Object.setPrototypeOf(result,PublicKeyCredential.prototype);resolve(result);
      };
      const timer=setTimeout(()=>{cleanup();reject(new DOMException("Timed out","NotAllowedError"));},Math.min(Math.max(key.timeout??60000,1000),60000));
      options.signal?.addEventListener("abort",abort,{once:true});window.addEventListener("message",receive);
      window.postMessage({channel:"pv-passkey-request",id,operation,options:request},location.origin);
    });
  }
  navigator.credentials.create=(options)=>ceremony("create",options);
  navigator.credentials.get=(options)=>ceremony("get",options);
})();
