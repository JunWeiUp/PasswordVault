import test from 'node:test';import assert from 'node:assert/strict';import WebSocket,{WebSocketServer} from 'ws';import {createGateway} from '../src/gateway.mjs';
const listen=server=>new Promise(resolve=>server.listen(0,'127.0.0.1',()=>resolve(server.address().port)));
test('origin rejected before token; verified origin bridges auth header and ciphertext',async()=>{
 const upstream=new WebSocketServer({port:0,host:'127.0.0.1',handleProtocols:()=> 'common-relay.v1'});await new Promise(r=>upstream.on('listening',r));
 let credential;upstream.on('connection',(ws,req)=>{credential=req.headers.authorization;ws.send(JSON.stringify({version:1}));ws.on('message',data=>ws.send(data,{binary:false}));});
 const gateway=createGateway({upstream:`ws://127.0.0.1:${upstream.address().port}`,origins:['http://127.0.0.1:9000'],allowLocalTest:true});const port=await listen(gateway.server);
 try {
  const rejected=new WebSocket(`ws://127.0.0.1:${port}/connect`,'passwordvault.gateway.v1',{origin:'https://attacker.invalid'});await new Promise(resolve=>rejected.on('error',resolve));assert.equal(credential,undefined);
  const client=new WebSocket(`ws://127.0.0.1:${port}/connect`,'passwordvault.gateway.v1',{origin:'http://127.0.0.1:9000'});await new Promise(resolve=>client.on('open',resolve));client.send(JSON.stringify({type:'authenticate',token:'synthetic-only'}));await new Promise(resolve=>client.once('message',resolve));assert.equal(credential,'Bearer synthetic-only');
  client.send('opaque-ciphertext');const echoed=await new Promise(resolve=>client.once('message',data=>resolve(data.toString())));assert.equal(echoed,'opaque-ciphertext');client.terminate();
 }finally{await gateway.close();for(const c of upstream.clients)c.terminate();await new Promise(r=>upstream.close(r));}
});
test('unconfigured origin, unsafe upstream and query credentials are rejected',()=>{
 assert.throws(()=>createGateway({upstream:'ws://example.invalid',origins:['https://example.invalid']}));
 assert.throws(()=>createGateway({upstream:'wss://example.invalid?token=secret',origins:['https://example.invalid']}));
 assert.throws(()=>createGateway({upstream:'wss://example.invalid',origins:['*']}));
});
test('null origins and missing authentication are rejected; exact extension origins are configurable',async()=>{
 const origin='chrome-extension://'+'a'.repeat(32);
 const gateway=createGateway({upstream:'ws://127.0.0.1:1',origins:[origin],allowLocalTest:true,handshakeMs:30});const port=await listen(gateway.server);
 try{
  const denied=new WebSocket(`ws://127.0.0.1:${port}/connect`,'passwordvault.gateway.v1',{origin:'null'});await new Promise(resolve=>denied.on('error',resolve));
  const client=new WebSocket(`ws://127.0.0.1:${port}/connect`,'passwordvault.gateway.v1',{origin});await new Promise(resolve=>client.on('open',resolve));const code=await new Promise(resolve=>client.on('close',resolve));assert.equal(code,1008);
 }finally{await gateway.close();}
});
