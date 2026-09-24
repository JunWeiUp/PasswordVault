import test from "node:test";
import assert from "node:assert/strict";
import "fake-indexeddb/auto";
import { readStorage, writeStorage } from "../test-build/storage.js";
test("persistent writes use compare-and-swap so concurrent tabs cannot overwrite newer data", async () => {
  assert.equal(await readStorage(), undefined);
  await writeStorage("encrypted-bundle-one", undefined);
  const results = await Promise.allSettled([
    writeStorage("encrypted-bundle-two", "encrypted-bundle-one"),
    writeStorage("encrypted-bundle-three", "encrypted-bundle-one"),
  ]);
  assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
  assert.equal(results.filter((r) => r.status === "rejected").length, 1);
  assert.equal(await readStorage(), "encrypted-bundle-two");
  await assert.rejects(writeStorage("overwrite", undefined));
});
