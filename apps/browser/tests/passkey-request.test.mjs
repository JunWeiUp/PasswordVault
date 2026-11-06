import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import ts from "typescript";
const source=await readFile(new URL("../src/passkey-request.ts",import.meta.url),"utf8");
const output=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
const {validatePasskeyRequest,PasskeyRequests}=await import(`data:text/javascript;base64,${Buffer.from(output).toString("base64")}`);
const challenge=Buffer.alloc(32,8).toString("base64url");
const options={challenge,rp:{id:"example.com"},user:{id:"dXNlcg",name:"Alice"},pubKeyCredParams:[{type:"public-key",alg:-7}]};
test("passkey requests bind origin, RP, canonical challenge and supported algorithms",()=>{
 const request=validatePasskeyRequest("create",options,"https://example.com/signup","https://example.com/signup");
 assert.equal(JSON.parse(request.clientDataJSON).origin,"https://example.com");
 for(const [o,page,top]of [[{...options,rp:{id:"com"}},"https://example.com","https://example.com"],[options,"http://example.com","http://example.com"],[options,"https://example.com","https://evil.com"],[{...options,challenge:"YQ"},"https://example.com","https://example.com"],[{...options,authenticatorSelection:{userVerification:"invalid"}},"https://example.com","https://example.com"],[{...options,pubKeyCredParams:[{type:"public-key",alg:-257}]},"https://example.com","https://example.com"]]) assert.throws(()=>validatePasskeyRequest("create",o,page,top));
});
test("passkey request tokens expire, are single use and cannot cross documents or navigation",()=>{
 const requests=new PasskeyRequests();
 const request=validatePasskeyRequest("get",{challenge},"https://example.com/login","https://example.com/login");
 let id=requests.add("doc","url",request,100);
 assert.equal(requests.take(id,"doc","url",101),request);
 assert.throws(()=>requests.take(id,"doc","url",102));
 id=requests.add("doc","url",request,100); assert.throws(()=>requests.take(id,"other","url",101));
 id=requests.add("doc","url",request,100); assert.throws(()=>requests.take(id,"doc","new-url",101));
 id=requests.add("doc","url",request,100); assert.throws(()=>requests.take(id,"doc","url",60100));
 id=requests.add("doc","url",request,100); requests.clear(); assert.throws(()=>requests.take(id,"doc","url",101));
});
