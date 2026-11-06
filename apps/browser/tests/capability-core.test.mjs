import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const {
  bootstrapCreate,
  bootstrapUnlock,
  bootstrapRecover,
  bootstrapRestoreRecovery,
  BrowserVault,
} = require("../wasm-test/vault_core.cjs");
const password = "Synthetic browser recovery fixture";
const call = (engine, request) =>
  JSON.parse(engine.command(JSON.stringify(request)));
function open(storage, key) {
  return new BrowserVault(storage, Uint8Array.from(Buffer.from(key, "base64")));
}
function fresh() {
  const value = JSON.parse(bootstrapCreate(password));
  return open(value.storage, value.key);
}

test("browser complete history retains old attachments and emergency archives restore them", () => {
  const engine = fresh();
  call(engine, {
    op: "save",
    item: {
      id: "note",
      type: "secureNote",
      title: "Fixture",
      note: "Original",
    },
  });
  call(engine, { op: "history-enable" });
  const file = call(engine, {
    op: "attachment-add",
    noteId: "note",
    name: "fixture.txt",
    mime: "text/plain",
    data: Buffer.from("ATTACHMENT_CANARY").toString("base64"),
  });
  const rich = {
    id: "note",
    type: "secureNote",
    title: "Fixture",
    note: "Attachment version",
    noteFormat: "rich-v1",
    noteDocument: {
      type: "doc",
      content: [{ type: "vaultAttachment", attrs: { attachmentId: file.id } }],
    },
  };
  call(engine, { op: "save", richNotes: true, item: rich });
  const revision = call(engine, { op: "history-list", id: "note" }).revisions[0]
    .id;
  call(engine, {
    op: "save",
    richNotes: true,
    item: {
      ...rich,
      note: "Later",
      noteDocument: { type: "doc", content: [] },
    },
  });
  call(engine, { op: "attachment-collect" });
  assert.equal(
    Buffer.from(
      call(engine, { op: "attachment-read", noteId: "note", id: file.id }).data,
      "base64",
    ).toString(),
    "ATTACHMENT_CANARY",
  );
  const key = call(engine, { op: "recovery-generate" }).key;
  call(engine, { op: "recovery-enable", key, currentPassword: password });
  const content = call(engine, { op: "recovery-export", key }).content;
  assert(!content.includes("CANARY"));
  assert(!engine.snapshot().includes("CANARY"));
  const recovery = JSON.parse(
    bootstrapRestoreRecovery(content, key, "New master fixture"),
  );
  const restored = open(recovery.storage, recovery.key);
  assert.equal(call(restored, { op: "list" }).items[0].note, "Later");
  call(restored, {
    op: "history-restore",
    id: "note",
    revisionId: revision,
    time: new Date().toISOString(),
  });
  assert.equal(
    call(restored, { op: "list" }).items[0].note,
    "Attachment version",
  );
  assert.equal(
    Buffer.from(
      call(restored, { op: "attachment-read", noteId: "note", id: file.id })
        .data,
      "base64",
    ).toString(),
    "ATTACHMENT_CANARY",
  );
  assert.equal(call(restored, { op: "recovery-status" }).enabled, false);
  assert.throws(() =>
    bootstrapRestoreRecovery(content, "wrong", "New master fixture"),
  );
  call(engine, { op: "history-prune", id: "note" });
  assert.equal(call(engine, { op: "history-list", id: "note" }).total, 1);
  assert.throws(() =>
    call(engine, { op: "attachment-read", noteId: "note", id: file.id }),
  );
  engine.free();
  restored.free();
});
test("recovery resets only the header and corrupted checkpoints cannot mutate an active vault", () => {
  const engine = fresh();
  call(engine, {
    op: "save",
    item: {
      id: "fixture",
      type: "password",
      title: "Original",
      password: "SYNTHETIC_CANARY",
    },
  });
  call(engine, { op: "history-enable" });
  const key = call(engine, { op: "recovery-generate" }).key;
  call(engine, { op: "recovery-enable", key, currentPassword: password });
  const before = engine.snapshot();
  const state = call(engine, { op: "list" });
  const damaged = JSON.parse(before);
  damaged.extras.ciphertext = "A" + damaged.extras.ciphertext.slice(1);
  if (damaged.extras.ciphertext === JSON.parse(before).extras.ciphertext)
    damaged.extras.ciphertext = "B" + damaged.extras.ciphertext.slice(1);
  assert.throws(() => engine.restoreCheckpoint(JSON.stringify(damaged)));
  assert.deepEqual(call(engine, { op: "list" }), state);
  assert.throws(() => bootstrapRecover(before, "wrong", "New fixture master"));
  const recovered = JSON.parse(
    bootstrapRecover(before, key, "New fixture master"),
  );
  assert.throws(() => bootstrapUnlock(recovered.storage, password));
  const reopened = open(recovered.storage, recovered.key);
  assert.deepEqual(call(reopened, { op: "list" }), state);
  assert.equal(
    bootstrapUnlock(recovered.storage, "New fixture master").length,
    32,
  );
  call(reopened, {
    op: "recovery-disable",
    currentPassword: "New fixture master",
  });
  assert.throws(() =>
    bootstrapRecover(reopened.snapshot(), key, "Other fixture master"),
  );
  engine.free();
  reopened.free();
});

test('format-six structured data archives work without enabling history; reviewed import is atomic',()=>{
 const engine=fresh();
 call(engine,{op:'save',item:{id:'card',type:'creditCard',title:'Synthetic card',card:{number:'4111111111111111'},customFields:[{id:'f',label:'Code',value:'SYNTHETIC_FIELD',kind:'concealed'}]}});
 assert.equal(call(engine,{op:'list'}).formatVersion,6);
 assert.equal(call(engine,{op:'history-status'}).enabled,false);
 const archive=call(engine,{op:'export',password:'Synthetic archive password'}).content;
 const other=fresh();call(other,{op:'import',content:archive,password:'Synthetic archive password'});
 assert.equal(call(other,{op:'list'}).items[0].customFields[0].value,'SYNTHETIC_FIELD');
 assert.equal(call(other,{op:'history-status'}).enabled,false);
 const data=Buffer.from('name,url,username,password\nFixture,https://example.com,synthetic,ImportedFixture\n').toString('base64');
 const request={op:'import-preview',format:'csv',data,mapping:{}};
 const preview=call(engine,request);assert.equal(preview.rows.length,1);
 const before=call(engine,{op:'list'});
 assert.throws(()=>call(engine,{...request,op:'import-commit',choices:{999:'add'}}));
 assert.deepEqual(call(engine,{op:'list'}),before);
 call(engine,{...request,op:'import-commit'});
 assert.equal(call(engine,{...request,op:'import-commit'}).skipped,1);
 assert.ok(call(engine,{op:'security-audit'}).catalogSources.length);
 assert(!engine.snapshot().includes('SYNTHETIC_FIELD'));
 other.free();engine.free();
});

test('browser draft recovery is encrypted and blocks incomplete backups until explicitly resolved',()=>{
 const engine=fresh();
 const draft={id:'draft-fixture',type:'secureNote',title:'Unfinished',note:'PRIVATE_DRAFT_CANARY'};
 call(engine,{op:'draft-save',item:draft});
 assert(!engine.snapshot().includes('PRIVATE_DRAFT_CANARY'));
 const storage=engine.snapshot();
 const reopened=new BrowserVault(storage,bootstrapUnlock(storage,password));
 assert.equal(call(reopened,{op:'draft-read'}).item.note,'PRIVATE_DRAFT_CANARY');
 assert.equal(call(reopened,{op:'list'}).items.length,0);
 assert.throws(()=>call(reopened,{op:'export',password:'Synthetic backup password'}));
 call(reopened,{op:'save',item:draft});call(reopened,{op:'draft-clear'});
 assert.equal(call(reopened,{op:'draft-read'}).item,null);
 assert.equal(call(reopened,{op:'list'}).items[0].note,'PRIVATE_DRAFT_CANARY');
 engine.free();reopened.free();
});
