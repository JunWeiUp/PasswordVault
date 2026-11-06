import test from 'node:test';import assert from 'node:assert/strict';import{spawn}from'node:child_process';import{createInterface}from'node:readline';import{createRequire}from'node:module';import{randomUUID}from'node:crypto';
const require=createRequire(import.meta.url);const {bootstrapCreate,BrowserVault}=require('../wasm-test/vault_core.cjs');
function fixture(path){const child=spawn(path,[],{stdio:['pipe','pipe','inherit']});const pending=[];createInterface({input:child.stdout}).on('line',line=>{const callback=pending.shift();if(!callback)return;try{const value=JSON.parse(line);value.error?callback.reject(new Error(value.error)):callback.resolve(value.ok);}catch(e){callback.reject(e);}});child.on('exit',()=>{for(const callback of pending)callback.reject(new Error('fixture closed'));});return{call:request=>new Promise((resolve,reject)=>{pending.push({resolve,reject});child.stdin.write(JSON.stringify(request)+'\n');}),close:()=>child.kill()};}
test('WASM ↔ real Swift CommonRelay envelopes traverse local gateway and native Rust vault', {skip:!process.env.PEER_NATIVE_FIXTURE||!process.env.PEER_SWIFT_FIXTURE,timeout:60_000},async()=>{
 const {default:WebSocket,WebSocketServer}=await import('../../../services/sync-gateway/node_modules/ws/wrapper.mjs');const{createGateway}=await import('../../../services/sync-gateway/src/gateway.mjs');
 const native=fixture(process.env.PEER_NATIVE_FIXTURE),swift=fixture(process.env.PEER_SWIFT_FIXTURE);const bootstrap=JSON.parse(bootstrapCreate('Synthetic Web interoperability passphrase'));const web=new BrowserVault(bootstrap.storage,Buffer.from(bootstrap.key,'base64'));const call=request=>JSON.parse(web.command(JSON.stringify(request)));
 let gateway,upstream,client;const nativePublic='a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209';
 try {
  const identity=call({op:'peer-transport-identity'});call({op:'peer-transport-configure',gateway:'wss://gateway.example/connect',endpoint:'wss://relay.example/relay/v1/ws',credential:{identity:{app:'passwordvault',group:'fixture-group',device:identity.device,public_key:identity.publicKey},token:'synthetic-interop-token'}});
  await native.call({op:'create',password:'Synthetic native interoperability passphrase'});const owner=await native.call({op:'relay-peer-create',device:'native',personal:true,transportKey:nativePublic});const member=call({op:'relay-peer-identity',device:identity.device,confirmPersonalSync:true,personal:true});
  await native.call({op:'relay-peer-authorize',library:owner.library,peer:identity.device,member:{publicKey:member.publicKey,transportKey:identity.publicKey,role:'editor'}});
  call({op:'relay-peer-join',library:member.library,expectedLibrary:owner.library,founderKey:owner.publicKey,envelope:await native.call({op:'relay-peer-export',library:owner.library,peer:identity.device})});
  call({op:'save',item:{id:'from-web',type:'secureNote',title:'WASM authored',note:'synthetic'}});
  const applied=new Promise((resolve,reject)=>{
   upstream=new WebSocketServer({port:0,host:'127.0.0.1',handleProtocols:()=> 'common-relay.v1'});
   upstream.on('connection',(socket,request)=>{
    try{assert.equal(request.headers.authorization,'Bearer synthetic-interop-token');}catch(e){reject(e);return;}
    socket.send(JSON.stringify({version:1,identity:{app:'passwordvault',group:'fixture-group',device:identity.device,public_key:identity.publicKey}}));
    socket.on('message',async bytes=>{try{
     const frame=JSON.parse(bytes);if(frame.type==='ack'){resolve();return;}assert.equal(frame.type,'message');
     const opened=await swift.call({op:'open',peer:identity.device,publicKey:identity.publicKey,id:frame.id,body:frame.body});
     await native.call({op:'relay-peer-receive',library:owner.library,envelope:JSON.parse(Buffer.from(opened.data,'base64').toString())});
     assert.equal((await native.call({op:'list'})).items[0].title,'WASM authored');
     await native.call({op:'save',item:{id:'from-native',type:'secureNote',title:'Native authored',note:'synthetic reply'}});
     const envelope=await native.call({op:'relay-peer-export',library:owner.library,peer:identity.device});const id=randomUUID().replaceAll('-','');
     const response=await swift.call({op:'seal',peer:identity.device,publicKey:identity.publicKey,id,value:{data:Buffer.from(JSON.stringify(envelope)).toString('base64')}});
     socket.send(JSON.stringify({type:'message',from:'native',id,body:response.body,offline:true}));
    }catch(e){reject(e);}});
   });
  });
  await new Promise(resolve=>upstream.on('listening',resolve));gateway=createGateway({upstream:`ws://127.0.0.1:${upstream.address().port}`,origins:['http://127.0.0.1:9090'],allowLocalTest:true});await new Promise(resolve=>gateway.server.listen(0,'127.0.0.1',resolve));
  client=new WebSocket(`ws://127.0.0.1:${gateway.server.address().port}/connect`,'passwordvault.gateway.v1',{origin:'http://127.0.0.1:9090'});
  const reply=new Promise((resolve,reject)=>{let welcome=false;client.on('message',bytes=>{try{const frame=JSON.parse(bytes);if(!welcome){welcome=true;assert.equal(frame.identity.public_key,identity.publicKey);const envelope=call({op:'relay-peer-export',library:owner.library,peer:'native'});const id=randomUUID().replaceAll('-','');const sealed=call({op:'peer-transport-seal',peer:'native',publicKey:nativePublic,id,value:{data:Buffer.from(JSON.stringify(envelope)).toString('base64')}});client.send(JSON.stringify({type:'message',to:'native',id,body:sealed.body,offline:true}));return;}
   assert.throws(()=>call({op:'peer-transport-open',peer:'native',publicKey:nativePublic,id:'wrong-context',body:frame.body}));
   const opened=call({op:'peer-transport-open',peer:'native',publicKey:nativePublic,id:frame.id,body:frame.body});call({op:'relay-peer-receive',library:owner.library,envelope:JSON.parse(Buffer.from(opened.data,'base64').toString())});assert.deepEqual(call({op:'list'}).items.map(i=>i.title).sort(),['Native authored','WASM authored']);client.send(JSON.stringify({type:'ack',from:'native',id:frame.id}));resolve();
  }catch(e){reject(e);}});client.on('error',reject);});
  await new Promise(resolve=>client.on('open',resolve));client.send(JSON.stringify({type:'authenticate',token:'synthetic-interop-token'}));await Promise.all([reply,applied]);
 }finally{client?.terminate();if(gateway)await gateway.close();if(upstream){for(const socket of upstream.clients)socket.terminate();await new Promise(resolve=>upstream.close(resolve));}web.free();native.close();swift.close();}
});
