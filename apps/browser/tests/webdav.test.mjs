import test from 'node:test';
import assert from 'node:assert/strict';
import {davBase,davChild,WebDAVClient} from '../test-build/webdav.js';
const config={url:'https://example.com/dav',username:'synthetic',password:'test',folder:'vault'};
test('WebDAV never follows untrusted listing URLs or sends credentials through redirects',async()=>{
 const base=davBase(config);assert.equal(base.href,'https://example.com/dav/vault/');
 for(const url of ['https://evil.example/file','../private','https://u:p@example.com/dav/vault/a','%252e%252e/private','a?redirect=1'])assert.throws(()=>davChild(base,url));
 for(const url of ['http://example.com/','https://u:p@example.com/','https://example.com/?q=1'])assert.throws(()=>davBase({...config,url}));
 const calls=[];const client=new WebDAVClient(config,new AbortController().signal,async(url,options)=>{calls.push({url,options});return new Response('encrypted fixture');});
 assert.equal(await client.request('PUT',new URL('fixture.pvault',base).href,'ENCRYPTED_ONLY'),'encrypted fixture');
 assert.equal(calls[0].options.redirect,'error');assert.equal(calls[0].options.credentials,'omit');assert.equal(calls[0].options.headers['If-None-Match'],'*');
 await assert.rejects(()=>client.request('GET','https://evil.example/x'));assert.equal(calls.length,1);
});
test('WebDAV failed and oversized responses are never accepted as backups',async()=>{
 for(const response of [new Response('failure',{status:403}),new Response('too large',{headers:{'content-length':String(65*1024*1024)}})]){
 const client=new WebDAVClient(config,new AbortController().signal,async()=>response);await assert.rejects(()=>client.request('GET'));
 }
});

test('default WebDAV transport preserves the browser global fetch receiver', async (context) => {
 let calls = 0;
 context.mock.method(globalThis, 'fetch', async function(input, options) {
  assert.equal(this, globalThis, 'Unbound fetch called as a client method causes Illegal invocation in browsers');
  calls++;
  assert.equal(String(input), 'https://example.com/dav/vault/');
  assert.equal(options.method, 'PROPFIND');
  assert.equal(options.redirect, 'error');
  assert.equal(options.credentials, 'omit');
  return new Response('synthetic WebDAV response', {status:207});
 });
 const client = new WebDAVClient(config, new AbortController().signal);
 assert.equal(await client.request('PROPFIND'), 'synthetic WebDAV response');
 assert.equal(calls, 1);
});
