import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import ts from "typescript";
const source = await readFile(
  new URL("../src/rich-note-state.ts", import.meta.url),
  "utf8",
);
const output = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2022,
  },
}).outputText;
const { RichSnapshotGate, mergeRichSource } = await import(
  "data:text/javascript;base64," + Buffer.from(output).toString("base64")
);

test("late snapshot cannot overwrite a newer request after timeout", async () => {
  const gate = new RichSnapshotGate(10);
  let oldID, newID;
  await assert.rejects(
    gate.request((id) => (oldID = id)),
    /unavailable/,
  );
  const latest = gate.request((id) => (newID = id));
  assert.notEqual(oldID, newID);
  assert.equal(
    gate.accept(oldID, () => ({ note: "stale" })),
    false,
  );
  assert.equal(
    gate.accept(newID, () => ({ note: "latest" })),
    true,
  );
  assert.deepEqual(await latest, { note: "latest" });
});

test("attachment persistence blocks snapshots and invalidates an already pending save", async () => {
  const gate = new RichSnapshotGate();
  const release = gate.hold();
  await assert.rejects(
    gate.request(() => assert.fail()),
    /busy/,
  );
  release();
  release(); // Balanced idempotent cleanup, including error/finally paths.
  let id;
  const pending = gate.request((value) => (id = value));
  const rejected = assert.rejects(pending, /busy/);
  const finish = gate.hold();
  await rejected;
  assert.equal(
    gate.accept(id, () => "partial"),
    false,
  );
  finish();
  const final = gate.request((value) => (id = value));
  gate.accept(id, () => "attachment included");
  assert.equal(await final, "attachment included");
});

test("closing rejects pending snapshots and malformed responses never become saved content", async () => {
  const gate = new RichSnapshotGate();
  let id;
  const malformed = gate.request((value) => (id = value));
  gate.accept(id, () => {
    throw Error("Invalid snapshot");
  });
  await assert.rejects(malformed, /Invalid/);
  const closing = gate.request(() => {});
  gate.close();
  await assert.rejects(closing, /closed/);
  await assert.rejects(
    gate.request(() => {}),
    /busy/,
  );
});

test("first rich edit retains original Markdown and metadata; invalid trees do not replace drafts", () => {
  const original = {
    id: "fixture",
    title: "Latest title",
    noteFormat: "markdown",
    note: "**original**",
    customFields: [{ id: "a" }],
  };
  assert.equal(
    mergeRichSource(original, original.note, original.note),
    original,
  );
  const payload = JSON.stringify({
    format: "rich-v1",
    document: { type: "doc", content: [] },
    text: "edited",
  });
  const first = mergeRichSource(original, payload);
  assert.deepEqual(first.noteOriginal, {
    format: "markdown",
    source: "**original**",
  });
  assert.equal(first.title, "Latest title");
  assert.deepEqual(first.customFields, original.customFields);
  assert.deepEqual(
    mergeRichSource(first, payload).noteOriginal,
    first.noteOriginal,
  );
  assert.throws(() =>
    mergeRichSource(first, '{"format":"rich-v1","document":{"type":"doc"}}'),
  );
  assert.equal(original.note, "**original**");
});

test("sandbox bridge binds the parent/channel and echoes the snapshot request ID", async () => {
  const listeners = new Map(),
    messages = [];
  const parent = { postMessage: (value) => messages.push(value) };
  const context = {
    parent,
    location: { hash: "#fixture-channel" },
    window: {
      pvEditor: { snapshot: async () => ({ source: "fixture", revision: 4 }) },
    },
    addEventListener: (name, callback) => listeners.set(name, callback),
  };
  vm.runInNewContext(
    await readFile(new URL("../editor/bridge.js", import.meta.url), "utf8"),
    context,
  );
  const listener = listeners.get("message");
  await listener({
    source: {},
    data: {
      channel: "fixture-channel",
      method: "snapshot",
      args: [false, "stale"],
    },
  });
  await listener({
    source: parent,
    data: { channel: "wrong", method: "snapshot", args: [false, "stale"] },
  });
  assert.equal(messages.length, 0);
  await listener({
    source: parent,
    data: {
      channel: "fixture-channel",
      method: "snapshot",
      args: [false, "request-2"],
    },
  });
  assert.equal(messages[0].request, "request-2");
  assert.equal(messages[0].result.revision, 4);
  assert.equal(messages[0].channel, "fixture-channel");
});
