import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { randomBytes } from "node:crypto";
import { createShareService, type Options } from "../src/server.ts";

const owner = "synthetic-owner-token-".repeat(3);
const other = "synthetic-other-token-".repeat(3);
test("explicit owner-client CORS allows only configured origins and never enables cookies",async()=>{
  const s=await setup({allowedOrigins:["https://vault.example.test"]});try {
    const response=await fetch(s.base+"/api/shares",{method:"OPTIONS",headers:{Origin:"https://vault.example.test","Access-Control-Request-Method":"POST"}});
    assert.equal(response.status,204);assert.equal(response.headers.get("access-control-allow-origin"),"https://vault.example.test");
    assert.equal(response.headers.get("access-control-allow-credentials"),null);
    assert.equal((await fetch(s.base+"/api/shares",{method:"OPTIONS",headers:{Origin:"https://untrusted.example"}})).status,403);
  }finally{await s.close();}
});
test("public WebCrypto/native-core share vector remains interoperable",async()=>{
  const fixture=JSON.parse(readFileSync(new URL("../../../crates/vault-core/tests/fixtures/share-v1.json",import.meta.url),"utf8"));
  const key=await crypto.subtle.importKey("raw",Buffer.from(fixture.key,"base64url"),"AES-GCM",false,["decrypt"]);
  const envelope=fixture.envelope;
  const clear=await crypto.subtle.decrypt({name:"AES-GCM",iv:Buffer.from(envelope.nonce,"base64"),additionalData:new TextEncoder().encode(`PasswordVaultShare/v1/${envelope.id}`)},key,Buffer.from(envelope.ciphertext,"base64"));
  assert.deepEqual(JSON.parse(new TextDecoder().decode(clear)),fixture.plaintext);
});
async function setup(overrides: Partial<Options> = {}) {
  const directory = mkdtempSync(join(tmpdir(), "pv-share-"));
  const service = createShareService({ directory, origin: "http://127.0.0.1", ownerTokens: [owner, other], secret: "synthetic-service-secret-".repeat(3), ...overrides });
  service.server.listen(0, "127.0.0.1"); await once(service.server, "listening");
  const address = service.server.address() as {port:number}; const base = `http://127.0.0.1:${address.port}`;
  const request = (path:string, method="GET", body?:unknown, token?:string, cookie?:string) => fetch(base+path, {method, headers:{...(body?{"Content-Type":"application/json"}:{}), ...(token?{Authorization:`Bearer ${token}`} : {}), ...(cookie?{Cookie:cookie}: {})}, body:body?JSON.stringify(body):undefined});
  return {...service, directory, base, request, close:async()=>{ service.server.close(); await once(service.server,"close"); rmSync(directory,{recursive:true,force:true}); }};
}
async function snapshot() {
  const id = randomBytes(16).toString("hex"); const key = randomBytes(32); const nonce = randomBytes(12);
  const cryptoKey = await crypto.subtle.importKey("raw",key,"AES-GCM",false,["encrypt","decrypt"]);
  const plaintext = { title:"Fixture", fields: {password:"PLAINTEXT_CANARY"}, attachments:[] };
  const ciphertext = Buffer.from(await crypto.subtle.encrypt({name:"AES-GCM",iv:nonce,additionalData:new TextEncoder().encode(`PasswordVaultShare/v1/${id}`)},cryptoKey,new TextEncoder().encode(JSON.stringify(plaintext))));
  return {key,cryptoKey,plaintext,envelope:{version:1,id,nonce:nonce.toString("base64"),ciphertext:ciphertext.toString("base64")}};
}

test("authenticated creation, ciphertext-only storage, decryption, ownership and revocation", async()=>{
  const s=await setup(); try {
    const fixture=await snapshot(); const body={...fixture.envelope,expiresIn:604800}; const path="/api/shares/"+body.id;
    assert.equal((await s.request("/api/shares","POST",body)).status,401);
    assert.equal((await s.request("/api/shares","POST",{...body,key:fixture.key.toString("hex")},owner)).status,400);
    assert.equal((await s.request("/api/shares","POST",body,owner)).status,201);
    assert.equal((await s.request("/api/shares","POST",body,owner)).status,409);
    const stored=readFileSync(join(s.directory,body.id+".json"),"utf8");
    assert(!stored.includes("PLAINTEXT_CANARY")); assert(!stored.includes(fixture.key.toString("hex")));
    const response=await s.request(path); assert.equal(response.headers.get("cache-control"),"no-store");
    const envelope=await response.json();
    const clear=await crypto.subtle.decrypt({name:"AES-GCM",iv:Buffer.from(envelope.nonce,"base64"),additionalData:new TextEncoder().encode(`PasswordVaultShare/v1/${body.id}`)},fixture.cryptoKey,Buffer.from(envelope.ciphertext,"base64"));
    assert.deepEqual(JSON.parse(new TextDecoder().decode(clear)),fixture.plaintext);
    assert.equal((await s.request(path,"DELETE",undefined,other)).status,404);
    assert.equal((await s.request(path,"DELETE",undefined,owner)).status,200);
    assert.equal((await s.request(path)).status,404);
    assert(!existsSync(join(s.directory,body.id+".json")));
  } finally {await s.close();}
});
test("expiry is enforced without depending on the cleanup timer",async()=>{
  let clock=1000; const s=await setup({now:()=>clock}); try {
    const {envelope}=await snapshot();
    assert.equal((await s.request("/api/shares","POST",{...envelope,expiresIn:3600},owner)).status,201);
    clock+=3600001;
    assert.equal((await s.request("/api/shares/"+envelope.id)).status,404);
    s.purge(); assert(!existsSync(join(s.directory,envelope.id+".json")));
  } finally {await s.close();}
});
test("recipient verification gates ciphertext, consumes codes and revocation invalidates sessions",async()=>{
  const mail:{email:string;code:string}[]=[];
  const s=await setup({sendCode:async(email,code)=>{mail.push({email,code});}}); try {
    const {envelope}=await snapshot(); const path="/api/shares/"+envelope.id;
    assert.equal((await s.request("/api/shares","POST",{...envelope,expiresIn:86400,recipientEmail:"fixture@example.test"},owner)).status,201);
    assert.equal((await s.request(path)).status,401);
    assert.equal((await s.request(path+"/challenge","POST",{email:"other@example.test"})).status,202); assert.equal(mail.length,0);
    assert.equal((await s.request(path+"/challenge","POST",{email:"fixture@example.test"})).status,202); assert.equal(mail.length,1);
    const verified=await s.request(path+"/verify","POST",{code:mail[0].code}); assert.equal(verified.status,200);
    const cookie=verified.headers.get("set-cookie")!.split(";")[0];
    assert(verified.headers.get("set-cookie")!.includes("HttpOnly"));
    assert.equal((await s.request(path,"GET",undefined,undefined,cookie)).status,200);
    assert.equal((await s.request(path+"/verify","POST",{code:mail[0].code})).status,403);
    assert.equal((await s.request(path,"DELETE",undefined,owner)).status,200);
    assert.equal((await s.request(path,"GET",undefined,undefined,cookie)).status,404);
    assert(!readFileSync(join(s.directory,"share.sqlite")).includes(Buffer.from("fixture@example.test")));
  } finally {await s.close();}
});
test("code attempt cap, absent SMTP, invalid expiry, oversized body and foreign origin fail closed",async()=>{
  const mail:string[]=[]; const s=await setup({maxBytes:4096,sendCode:async(_email,code)=>{mail.push(code);}}); try {
    const {envelope}=await snapshot(); const path="/api/shares/"+envelope.id;
    assert.equal((await s.request("/api/shares","POST",{...envelope,expiresIn:1},owner)).status,400);
    assert.equal((await s.request("/api/shares","POST",{...envelope,ciphertext:"A".repeat(5000),expiresIn:3600},owner)).status,413);
    assert.equal((await fetch(s.base+"/api/capabilities",{headers:{Origin:"https://untrusted.example"}})).status,403);
    assert.equal((await s.request("/api/shares","POST",{...envelope,expiresIn:3600,recipientEmail:"fixture@example.test"},owner)).status,201);
    await s.request(path+"/challenge","POST",{email:"fixture@example.test"});
    for(let i=0;i<5;i++) assert.equal((await s.request(path+"/verify","POST",{code:mail[0]==="000000"?"111111":"000000"})).status,403);
    assert.equal((await s.request(path+"/verify","POST",{code:mail[0]})).status,403);
  } finally {await s.close();}
  const noMail=await setup(); try {
    const {envelope}=await snapshot();
    assert.equal((await noMail.request("/api/shares","POST",{...envelope,expiresIn:3600,recipientEmail:"fixture@example.test"},owner)).status,503);
  } finally {await noMail.close();}
});
