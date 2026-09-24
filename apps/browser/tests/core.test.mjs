import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFile, readdir } from "node:fs/promises";
const require = createRequire(import.meta.url);
const {
  bootstrapCreate,
  bootstrapUnlock,
  BrowserVault,
} = require("../wasm-test/vault_core.cjs");
const pass = "Synthetic browser test passphrase 2026";
const call = (vault, r) => JSON.parse(vault.command(JSON.stringify(r)));
const open = () => {
  const bundle = JSON.parse(bootstrapCreate(pass));
  return {
    storage: bundle.storage,
    vault: new BrowserVault(
      bundle.storage,
      Uint8Array.from(Buffer.from(bundle.key, "base64")),
    ),
  };
};
test("browser storage remains encrypted, unlock validates, and an edited bundle is rejected", () => {
  const { vault } = open();
  const record = {
    id: "synthetic",
    type: "secureNote",
    title: "PRIVATE-TITLE-CANARY",
    note: "PRIVATE-BODY-CANARY",
  };
  call(vault, { op: "save", item: record });
  const saved = vault.snapshot();
  assert(!saved.includes(record.title));
  assert(!saved.includes(record.note));
  assert(!saved.includes(pass));
  assert.throws(() => bootstrapUnlock(saved, "incorrect"));
  const key = bootstrapUnlock(saved, pass);
  const reopened = new BrowserVault(saved, key);
  key.fill(0);
  assert.equal(call(reopened, { op: "list" }).items[0].note, record.note);
  const changed = JSON.parse(saved);
  changed.payload.ciphertext = "AAAA";
  assert.throws(
    () =>
      new BrowserVault(JSON.stringify(changed), bootstrapUnlock(saved, pass)),
  );
  vault.free();
  reopened.free();
});
test("rollback checkpoint, password rotation, legacy import, and strict domain matching", () => {
  const { vault } = open();
  const before = vault.snapshot();
  call(vault, {
    op: "save",
    item: {
      id: "account",
      type: "password",
      title: "Fixture",
      username: "test@example.com",
      password: "synthetic-password",
      url: "https://example.com",
    },
  });
  assert.equal(
    call(vault, { op: "matches", origin: "https://example.com/login" }).length,
    1,
  );
  for (const origin of [
    "http://example.com",
    "https://example.com.evil.test",
    "https://sub.example.com",
  ])
    assert.equal(call(vault, { op: "matches", origin }).length, 0);
  assert.throws(() =>
    call(vault, { op: "fill", id: "account", origin: "https://attacker.test" }),
  );
  vault.restoreCheckpoint(before);
  assert.equal(call(vault, { op: "list" }).items.length, 0);
  const fixture = {
    items: [
      {
        id: "legacy",
        title: "Fixture note",
        type: "secureNote",
        note: "Synthetic note",
        unknownField: { keep: true },
      },
    ],
  };
  call(vault, { op: "import", content: JSON.stringify(fixture) });
  assert.equal(call(vault, { op: "list" }).items[0].unknownField.keep, true);
  call(vault, {
    op: "change-password",
    currentPassword: pass,
    newPassword: "Replacement synthetic passphrase",
  });
  const changed = vault.snapshot();
  assert.throws(() => bootstrapUnlock(changed, pass));
  assert.equal(
    bootstrapUnlock(changed, "Replacement synthetic passphrase").length,
    32,
  );
  vault.free();
});
test("MV3 package uses lightweight origin-guarded login listeners, static worker imports, and no Flutter runtime", async () => {
  const manifest = JSON.parse(
    await readFile(new URL("../dist/manifest.json", import.meta.url)),
  );
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.content_scripts, [
    {
      matches: ["https://*/*", "http://*/*"],
      js: ["login-observer.js"],
      all_frames: true,
      run_at: "document_idle",
    },
    {
      matches: ["https://*/*", "http://*/*"],
      js: ["inline-fields.js"],
      all_frames: true,
      run_at: "document_idle",
    },
  ]);
  assert.deepEqual(manifest.host_permissions, ["https://*/*", "http://*/*"]);
  assert.equal(manifest.optional_host_permissions, undefined);
  assert.equal(manifest.permissions.includes("activeTab"), true);
  assert.equal(manifest.permissions.includes("nativeMessaging"), true);
  const worker = await readFile(
    new URL("../dist/background.js", import.meta.url),
    "utf8",
  );
  assert(
    !/\bimport\s*\(/.test(worker),
    "MV3 service workers cannot dynamically import modules",
  );
  const files = await readdir(new URL("../dist/assets/", import.meta.url));
  assert(!files.some((s) => /flutter|canvaskit/i.test(s)));
});

test("WASM matches the same host across ports, rejects other hosts and malformed writes", () => {
  const { vault } = open();
  call(vault, {
    op: "save",
    item: {
      id: "account",
      type: "password",
      title: "Fixture",
      url: "https://example.com",
      password: "fixture",
    },
  });
  assert.equal(
    call(vault, { op: "matches", origin: "https://example.com:8443" }).length,
    1,
  );
  assert.equal(
    call(vault, {
      op: "fill",
      origin: "https://example.com:8443",
      id: "account",
    }).password,
    "fixture",
  );
  for (const origin of [
    "https://sub.example.com:8443",
    "https://example.com.attacker.test:8443",
    "http://example.com:8443",
  ])
    assert.throws(() => call(vault, { op: "fill", origin, id: "account" }));
  const before = call(vault, { op: "list" });
  assert.throws(() =>
    call(vault, { op: "create-shared", name: "", time: "fixture" }),
  );
  assert.deepEqual(call(vault, { op: "list" }), before);
  vault.free();
});

test("extension pages avoid Chromium cross-world modulepreload warnings", async () => {
  for (const name of ["popup.html", "index.html"]) {
    const html = await readFile(
      new URL(`../dist/${name}`, import.meta.url),
      "utf8",
    );
    assert.equal(html.includes('rel="modulepreload"'), false);
  }
});
