import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {tileFor,TILE_TONES} from "../test-build/tiles.js";
import {syncTone} from "../test-build/popup-state.js";
test("record tiles use a stable tone and the first character",()=>{
 assert.deepEqual(tileFor("github"),tileFor("github"));
 assert.equal(tileFor("github").initial,"G");
 assert.equal(tileFor("  示例账号").initial,"示");
 assert.equal(tileFor("").initial,"?");
 assert.equal(tileFor(undefined).initial,"?");
 const tones=new Set(["a","b","c","d","e","f","g","h","Example","Bank"].map(name=>tileFor(name).tone));
 assert.ok(tones.size>2);
 for(const tone of tones)assert.ok(tone>=0&&tone<TILE_TONES);
});
test("sync state is neutral when the Mac is disconnected with nothing pending",()=>{
 assert.equal(syncTone({queued:2,available:false}),"pending");
 assert.equal(syncTone({queued:0,available:false}),"off");
 assert.equal(syncTone({queued:0,available:true}),"done");
 assert.equal(syncTone({}),"done");
});
test("card and identity fills confirm inside the popup, never with window.confirm",async()=>{
 const source=await readFile(new URL("../src/StructuredFill.tsx",import.meta.url),"utf8");
 assert.equal(/\bconfirm\(/.test(source),false);
 assert.match(source,/confirm-card/);
 assert.match(source,/includeSecurityCode:security/);
 assert.match(source,/setSecurity\(false\)/);
});
