import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {bootstrapCreate,BrowserVault}=require('../wasm-test/vault_core.cjs');
const secret='Synthetic scope test passphrase';
const call=(vault,request)=>JSON.parse(vault.command(JSON.stringify(request)));
test('registration targets personal scope while family is selected and scope failures are atomic',()=>{
 const bootstrap=JSON.parse(bootstrapCreate(secret));
 const vault=new BrowserVault(bootstrap.storage,Buffer.from(bootstrap.key,'base64'));
 try {
  const family=call(vault,{op:'relay-peer-create',device:'test-device',personal:false,name:'Family'}).library;
  call(vault,{op:'relay-peer-switch',library:family});
  const request={op:'passkey-create',rpId:'example.com',origin:'https://example.com',userHandle:Buffer.from('alice').toString('base64url'),userName:'Alice',currentPassword:secret,clientDataJSON:JSON.stringify({type:'webauthn.create',origin:'https://example.com',challenge:Buffer.alloc(32,7).toString('base64url'),crossOrigin:false})};
  const response=call(vault,request);
  assert.equal(response.library,'');assert.ok(response.itemId);
  assert.equal(call(vault,{op:'list'}).items.length,0);
  assert.equal(call(vault,{op:'passkey-index'}).passkeys[0].library,'');
  assert.throws(()=>call(vault,{...request,library:family}));
  assert.throws(()=>call(vault,{...request,clientDataJSON:'invalid'}));
  assert.equal(call(vault,{op:'list'}).items.length,0);
  assert.throws(()=>call(vault,{...request,excluded:[response.id]}));
  call(vault,{op:'relay-peer-switch',library:''});
  assert.equal(call(vault,{op:'list'}).items.length,1);
 } finally { vault.free(); }
});
