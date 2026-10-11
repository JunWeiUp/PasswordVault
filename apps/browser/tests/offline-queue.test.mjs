import test from "node:test";
import assert from "node:assert/strict";
import "fake-indexeddb/auto";
import {
  enqueue,
  queuedCount,
  syncQueue,
} from "../test-build/offline-queue.js";
const login = {
  origin: "https://signup.example",
  username: "synthetic-user",
  password: "synthetic-password",
};
function inspect(store, action) {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open("PasswordVaultOfflineQueueV1", 1);
    r.onsuccess = () => {
      const db = r.result;
      const tx = db.transaction(store, "readwrite");
      const request = action(tx.objectStore(store));
      tx.oncomplete = () => {
        resolve(request.result);
        db.close();
      };
      tx.onabort = () => reject(tx.error);
    };
  });
}
test("offline queue encrypts, survives reload, retains failed deliveries and deletes only acknowledged records", async () => {
  await enqueue(login);
  assert.equal(await queuedCount(), 1);
  const records = await inspect("queue", (s) => s.getAll());
  assert.equal(records[0].password, undefined);
  assert.ok(
    !new TextDecoder().decode(records[0].ciphertext).includes(login.password),
  );
  const key = await inspect("key", (s) => s.get("aes"));
  assert.equal(key.extractable, false);
  await assert.rejects(crypto.subtle.exportKey("raw", key));
  await assert.rejects(
    syncQueue(async (item) => {
      assert.deepEqual(item, login);
      throw Error("disconnected");
    }),
  );
  assert.equal(await queuedCount(), 1);
  const restarted = await import("../test-build/offline-queue.js?restart");
  await restarted.syncQueue(async (item) => assert.deepEqual(item, login));
  assert.equal(await queuedCount(), 0);
});
test("tampered ciphertext cannot be delivered or silently removed", async () => {
  await enqueue(login);
  const [record] = await inspect("queue", (s) => s.getAll());
  new Uint8Array(record.ciphertext)[0] ^= 1;
  await inspect("queue", (s) => s.put(record));
  let delivered = false;
  await assert.rejects(
    syncQueue(async () => {
      delivered = true;
    }),
  );
  assert.equal(delivered, false);
  assert.equal(await queuedCount(), 1);
});
