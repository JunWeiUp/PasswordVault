import test from 'node:test';import assert from 'node:assert/strict';import {createRequire}from'node:module';import{createHash}from'node:crypto';
const require=createRequire(import.meta.url);const{bootstrapCreate,bootstrapUnlock,BrowserVault}=require('../wasm-test/vault_core.cjs');
const pass='Synthetic peer fixture passphrase';const call=(v,r)=>JSON.parse(v.command(JSON.stringify(r)));
const open=()=>{const b=JSON.parse(bootstrapCreate(pass));return new BrowserVault(b.storage,Buffer.from(b.key,'base64'));};
function enroll(a,b,personal=true,role='editor'){
 const ai=call(a,{op:'peer-transport-identity'}),bi=call(b,{op:'peer-transport-identity'});
 const ac=call(a,{op:'relay-peer-create',device:ai.device,personal,transportKey:ai.publicKey,name:'Family'});
 const bc=call(b,{op:'relay-peer-identity',device:bi.device,confirmPersonalSync:true,personal});
 call(a,{op:'relay-peer-authorize',library:ac.library,peer:bi.device,member:{publicKey:bc.publicKey,transportKey:bi.publicKey,role}});
 call(b,{op:'relay-peer-join',library:bc.library,expectedLibrary:ac.library,founderKey:ac.publicKey,envelope:call(a,{op:'relay-peer-export',library:ac.library,peer:bi.device})});
 return{library:ac.library,a:ai,b:bi};
}
test('WASM two independent replicas converge without a Mac and reject reader writes atomically',()=>{
 const a=open(),b=open();try{const{library,a:ai,b:bi}=enroll(a,b);
 call(a,{op:'save',item:{id:'x',type:'secureNote',title:'A',note:'one'}});call(b,{op:'save',item:{id:'x',type:'secureNote',title:'B',note:'two'}});
 call(a,{op:'relay-peer-receive',library,envelope:call(b,{op:'relay-peer-export',library,peer:ai.device})});assert.equal(call(a,{op:'relay-peer-status',library}).conflicts['item:x'].length,2);
 call(a,{op:'relay-peer-resolve',library,key:'item:x',value:{id:'x',type:'secureNote',title:'Resolved',note:'kept'}});
 const envelope=call(a,{op:'relay-peer-export',library,peer:bi.device});call(b,{op:'relay-peer-receive',library,envelope});call(b,{op:'relay-peer-receive',library,envelope});assert.equal(call(b,{op:'list'}).items[0].title,'Resolved');
 call(a,{op:'relay-peer-authorize',library,peer:bi.device,member:{publicKey:call(b,{op:'relay-peer-status',library}).publicKey,transportKey:bi.publicKey,role:'reader'}});call(b,{op:'relay-peer-receive',library,envelope:call(a,{op:'relay-peer-export',library,peer:bi.device})});
 assert.throws(()=>call(b,{op:'save',item:{id:'x',type:'secureNote',title:'forbidden'}}));assert.equal(call(b,{op:'list'}).items[0].title,'Resolved');
 }finally{a.free();b.free();}
});
test('WASM family switching isolates IDs/history and encrypted fragmented delivery survives restart',()=>{
 const a=open();let b=open();try{
 call(a,{op:'save',item:{id:'x',type:'secureNote',title:'Private'}});const{library,a:ai,b:bi}=enroll(a,b,false);
 call(a,{op:'relay-peer-switch',library});call(a,{op:'save',item:{id:'x',type:'secureNote',title:'Shared',note:'s'.repeat(140000)}});
 const envelope=call(a,{op:'relay-peer-export',library,peer:bi.device});const bytes=Buffer.from(JSON.stringify(envelope));const digest=createHash('sha256').update(bytes).digest('hex');const count=Math.ceil(bytes.length/65536);
 for(let index=count-1;index>=0;index--){const chunk={protocol:'peer-v2-chunk',library,transfer:digest.slice(0,32),digest,index,count,total:bytes.length,data:bytes.subarray(index*65536,(index+1)*65536).toString('base64')};call(b,{op:'relay-peer-receive',library,sender:ai.device,envelope:chunk});if(index===count-1){const storage=b.snapshot();assert(!storage.includes('Shared'));b.free();b=new BrowserVault(storage,bootstrapUnlock(storage,pass));}}
 call(b,{op:'relay-peer-switch',library});assert.equal(call(b,{op:'list'}).items[0].title,'Shared');assert.equal(call(b,{op:'history-list',id:'x'}).total,1);
 call(a,{op:'relay-peer-switch',library:''});assert.equal(call(a,{op:'list'}).items[0].title,'Private');
 }finally{a.free();b.free();}
});
test('WASM stale editing bases reject remote overwrite and preserve unsaved draft',()=>{
 const a=open(),b=open();try{const {library,a:ai,b:bi}=enroll(a,b);call(a,{op:'save',item:{id:'x',type:'secureNote',title:'Base'}});call(b,{op:'relay-peer-receive',library,envelope:call(a,{op:'relay-peer-export',library,peer:bi.device})});
 const draft=call(a,{op:'list'}).items[0];const remote=call(b,{op:'list'}).items[0];call(b,{op:'save',item:{...remote,title:'Remote change'}});call(a,{op:'relay-peer-receive',library,envelope:call(b,{op:'relay-peer-export',library,peer:ai.device})});
 assert.throws(()=>call(a,{op:'save',item:{...draft,title:'Unsaved local change'}}),/changed on another device/i);assert.equal(call(a,{op:'list'}).items[0].title,'Remote change');
 assert(!JSON.stringify(call(a,{op:'relay-peer-export',library,peer:bi.device})).includes('_peerBaseHeads'));
 }finally{a.free();b.free();}
});
test('loopback gateway transport needs explicit fixture flag and both exact local endpoints',()=>{
 const web=open();try{const identity=call(web,{op:'peer-transport-identity'});const credential={identity:{app:'passwordvault',group:'fixture',device:identity.device,public_key:identity.publicKey},token:'synthetic'};
 const configure=(gateway,endpoint,flag)=>call(web,{op:'peer-transport-configure',gateway,endpoint,credential:{...credential,testOnlyLoopback:flag}});
 assert.throws(()=>configure('ws://127.0.0.1:8080/connect','ws://127.0.0.1:8081/relay/v1/ws',false));
 assert.throws(()=>configure('ws://127.0.0.1:8080/connect','wss://remote.invalid/relay/v1/ws',true));
 assert.throws(()=>configure('ws://127.0.0.1.evil:8080/connect','ws://localhost:8081/relay/v1/ws',true));
 assert.throws(()=>configure('ws://user@localhost:8080/connect','ws://localhost:8081/relay/v1/ws',true));
 assert.throws(()=>configure('ws://localhost:8080/connect?token=x','ws://localhost:8081/relay/v1/ws',true));
 assert.equal(configure('ws://127.0.0.1:8080/connect','ws://localhost:8081/relay/v1/ws',true).group,'fixture');
 }finally{web.free();}
});
test('family invitations cannot be upgraded to personal enrollment and never export local private entries',()=>{
 const a=open(),b=open();try{
 call(b,{op:'save',item:{id:'private',type:'secureNote',title:'PRIVATE_ENROLLMENT_CANARY'}});const owner=call(a,{op:'relay-peer-create',device:'owner',personal:false});
 assert.throws(()=>call(b,{op:'relay-peer-identity',device:'reader',personal:true}));
 const wrong=call(b,{op:'relay-peer-identity',device:'reader',personal:true,confirmPersonalSync:true});call(a,{op:'relay-peer-authorize',library:owner.library,peer:'reader',member:{publicKey:wrong.publicKey,role:'editor'}});
 assert.throws(()=>call(b,{op:'relay-peer-join',library:wrong.library,expectedLibrary:owner.library,founderKey:owner.publicKey,envelope:call(a,{op:'relay-peer-export',library:owner.library,peer:'reader'})}));call(b,{op:'relay-peer-cancel-join',library:wrong.library});
 const right=call(b,{op:'relay-peer-identity',device:'reader',personal:false});call(a,{op:'relay-peer-authorize',library:owner.library,peer:'reader',member:{publicKey:right.publicKey,role:'reader'}});call(b,{op:'relay-peer-join',library:right.library,expectedLibrary:owner.library,founderKey:owner.publicKey,envelope:call(a,{op:'relay-peer-export',library:owner.library,peer:'reader'})});
 assert(!JSON.stringify(call(b,{op:'relay-peer-export',library:owner.library,peer:'owner'})).includes('PRIVATE_ENROLLMENT_CANARY'));call(b,{op:'relay-peer-switch',library:owner.library});const doc=call(b,{op:'list'});assert.equal(doc.settings._peerLibraryReadOnly,true);assert.equal(doc.settings._peerLibraryRole,'reader');call(b,{op:'relay-peer-switch',library:''});assert.equal(call(b,{op:'list'}).items[0].title,'PRIVATE_ENROLLMENT_CANARY');
 }finally{a.free();b.free();}
});
test('explicit personal enrollment while viewing a family shares only the personal snapshot',()=>{
 const owner=open(),recipient=open();try{
 call(recipient,{op:'save',item:{id:'personal',type:'secureNote',title:'PERSONAL_ONLY'}});const family=call(recipient,{op:'relay-peer-create',device:'recipient',personal:false});call(recipient,{op:'relay-peer-switch',library:family.library});call(recipient,{op:'save',item:{id:'family',type:'secureNote',title:'FAMILY_ONLY'}});
 const personal=call(owner,{op:'relay-peer-create',device:'owner',personal:true});const invitation=call(recipient,{op:'relay-peer-identity',device:'recipient',personal:true,confirmPersonalSync:true});call(owner,{op:'relay-peer-authorize',library:personal.library,peer:'recipient',member:{publicKey:invitation.publicKey,role:'editor'}});call(recipient,{op:'relay-peer-join',library:invitation.library,expectedLibrary:personal.library,founderKey:personal.publicKey,envelope:call(owner,{op:'relay-peer-export',library:personal.library,peer:'recipient'})});
 const outgoing=JSON.stringify(call(recipient,{op:'relay-peer-export',library:personal.library,peer:'owner'}));assert(outgoing.includes('PERSONAL_ONLY'));assert(!outgoing.includes('FAMILY_ONLY'));assert.equal(call(recipient,{op:'list'}).items[0].title,'FAMILY_ONLY');
 }finally{owner.free();recipient.free();}
});
