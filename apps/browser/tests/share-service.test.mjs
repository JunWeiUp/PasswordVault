import test from "node:test";
import assert from "node:assert/strict";
import { ShareService } from "../test-build/share-service.js";

test("share client keeps keys in fragments and ignores service-supplied viewer URLs", async () => {
  const id = "a".repeat(32),
    key = "A".repeat(43);
  const service = new ShareService(
    "https://share.example.test",
    "synthetic-owner-token".repeat(3),
    async (url, options) => {
      assert.equal(String(url), "https://share.example.test/api/shares");
      assert.equal(options.redirect, "error");
      assert.equal(options.credentials, "omit");
      const body = JSON.parse(options.body);
      assert.equal(body.key, undefined);
      assert(!options.body.includes(key));
      return new Response(
        JSON.stringify({ id, url: "https://untrusted.example" }),
        { status: 201 },
      );
    },
  );
  const link = await service.create(
    { version: 1, id, key, nonce: "synthetic", ciphertext: "synthetic" },
    604800,
  );
  assert.equal(link, `https://share.example.test/s/${id}#${key}`);
});
test("share client rejects unsafe endpoints and a mismatched response ID", async () => {
  for (const endpoint of [
    "http://remote.example",
    "https://user:fixture@example.test",
    "https://example.test/path",
    "https://example.test#fragment",
  ])
    assert.throws(() => new ShareService(endpoint, "t".repeat(40)));
  const service = new ShareService(
    "https://share.example.test",
    "t".repeat(40),
    async () =>
      new Response(JSON.stringify({ id: "b".repeat(32) }), { status: 201 }),
  );
  await assert.rejects(
    service.create(
      {
        version: 1,
        id: "a".repeat(32),
        key: "A".repeat(43),
        nonce: "synthetic",
        ciphertext: "synthetic",
      },
      604800,
    ),
  );
});

test("default share transport preserves the browser global fetch receiver", async (context) => {
  let calls = 0;
  context.mock.method(globalThis, "fetch", async function (input, options) {
    assert.equal(this, globalThis, "Unbound fetch called as a service method causes Illegal invocation in browsers");
    calls++;
    assert.equal(String(input), "https://share.example.test/api/capabilities");
    assert.equal(options.redirect, "error");
    assert.equal(options.credentials, "omit");
    return new Response(JSON.stringify({ smtp: false }), { status: 200 });
  });
  // Deliberately omit the injected transport: arrow-function mocks hid this regression.
  const service = new ShareService("https://share.example.test", "synthetic-owner-token".repeat(3));
  assert.deepEqual(await service.capabilities(), { smtp: false });
  assert.equal(calls, 1);
});
