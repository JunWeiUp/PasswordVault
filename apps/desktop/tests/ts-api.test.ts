// Fast pure-TS unit tests for shared MCP schema, note asset helpers, and vault metadata.
// Runs in milliseconds without opening any native window or vault.
import { expect, test } from "nsh/test";
import { MCP_INSTRUCTIONS, MCP_TOOLS, MCP_TOOL_BY_NAME } from "../ui/api/mcpTools";
import { AI_ERRORS, AI_OPS, aiError } from "../ui/api/aiAccess";
import {
  buildAiClientViews,
  clientStateLabel,
  clientSubline,
  countAiClientStates,
  filterAiClients,
  findDuplicateClientNames,
  pruneClientNotes,
} from "../ui/api/aiClients";
import {
  assetErrorText,
  canExtractAssetText,
  collectReferencedIds,
  enrichNoteAsset,
  formatAssetSize,
  formatBlobShort,
  formatDelta,
  isBlockedExternalAsset,
  recommendedApps,
  removeAttachmentFromDoc,
  replaceAttachmentInDoc,
} from "../ui/api/noteAssets";
import { readItemMeta, readUiPref } from "../ui/api/extensions";
import { destOf, errorText, inDest, type Item } from "../ui/api/vaultMeta";

test("shared tools.schema.json drives the five CRUD MCP tools without duplicates", () => {
  expect(MCP_INSTRUCTIONS.length > 50).toBe(true);
  expect(MCP_TOOLS.length).toBe(5);
  const names = MCP_TOOLS.map((t) => t.name);
  expect(new Set(names).size).toBe(5);
  for (const required of ["find", "read", "create", "update", "delete"]) {
    expect(MCP_TOOL_BY_NAME[required]?.uiSummary.length).toBeGreaterThan(0);
    expect(MCP_TOOL_BY_NAME[required]?.description.length).toBeGreaterThan(0);
  }
  expect(MCP_TOOL_BY_NAME.find.readOnly).toBe(true);
  expect(MCP_TOOL_BY_NAME.read.readOnly).toBe(true);
  expect(MCP_TOOL_BY_NAME.create.readOnly).toBe(false);
  expect(MCP_TOOL_BY_NAME.update.readOnly).toBe(false);
  expect(MCP_TOOL_BY_NAME.delete.readOnly).toBe(false);
});

test("noteAssets pure TS helpers format sizes, recommend apps, and update rich-v1 attachment nodes", () => {
  expect(formatAssetSize(512)).toBe("512 B");
  expect(formatAssetSize(2048)).toBe("2.0 KB");
  expect(formatAssetSize(5 * 1024 * 1024)).toBe("5.0 MB");
  expect(formatDelta(0)).toBe("大小不变");
  expect(formatDelta(2048)).toBe("+2.0 KB");
  expect(formatDelta(-1024)).toBe("-1.0 KB");

  expect(recommendedApps("report.pdf", "application/pdf").some((a) => a.app === "Preview")).toBe(true);
  expect(recommendedApps("contract.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document").some((a) => a.app === "Microsoft Word")).toBe(true);
  expect(assetErrorText("Error: BlockedExecutable")).toContain("可执行文件");
  expect(assetErrorText("AssetTooLarge")).toContain("100 MB");

  const doc: any = {
    type: "doc",
    content: [
      { type: "paragraph", content: [{ type: "text", text: "hi" }] },
      { type: "vaultAttachment", attrs: { attachmentId: "att-1", name: "a.pdf", mime: "application/pdf", size: 100 } },
      { type: "vaultImage", attrs: { attachmentId: "img-1", name: "b.png", mime: "image/png" } },
    ],
  };
  const refs = new Set<string>();
  collectReferencedIds(doc, refs);
  expect([...refs].sort()).toEqual(["att-1", "img-1"]);

  expect(replaceAttachmentInDoc(doc, "att-1", { id: "att-2", name: "a-v2.pdf", mime: "application/pdf", size: 220 })).toBe(true);
  expect(doc.content[1].attrs.attachmentId).toBe("att-2");
  expect(doc.content[1].attrs.size).toBe(220);

  expect(removeAttachmentFromDoc(doc, "att-2")).toBe(true);
  expect(doc.content.length).toBe(2);
});

test("vaultMeta and aiAccess helpers map destinations and errors cleanly", () => {
  const note: Item = { id: "n1", type: "secureNote", title: "测试", isFavorite: true };
  expect(destOf("secureNote")).toBe("notes");
  expect(destOf("creditCard")).toBe("wallets");
  expect(inDest(note, "notes")).toBe(true);
  expect(inDest(note, "favorites")).toBe(true);
  expect(inDest({ ...note, isDeleted: true }, "trash")).toBe(true);
  expect(inDest({ ...note, isDeleted: true }, "notes")).toBe(false);
  expect(errorText("Error: Locked")).toBe("密码库已锁定。");
  expect(aiError("Error: AssetTextDenied")).toBe(AI_ERRORS.AssetTextDenied);
  expect(AI_OPS.update).toBe("修改");
  expect(AI_OPS.delete).toBe("移到回收站");
});

test("TS asset classification and generic uiMeta / uiPrefs pass-through helpers work without Rust formatting", () => {
  expect(formatBlobShort("0123456789abcdef")).toBe("blobs/0123…cdef.pvblob");
  expect(formatBlobShort("short")).toBe("blobs/short.pvblob");
  expect(formatBlobShort(undefined)).toBe(undefined);

  expect(canExtractAssetText("report.pdf", "application/pdf")).toBe(true);
  expect(canExtractAssetText("budget.xlsx", "application/octet-stream")).toBe(true);
  expect(canExtractAssetText("photo.png", "image/png")).toBe(false);

  expect(isBlockedExternalAsset("run.command")).toBe(true);
  expect(isBlockedExternalAsset("install.dmg")).toBe(true);
  expect(isBlockedExternalAsset("contract.docx")).toBe(false);

  const enriched = enrichNoteAsset({
    id: "att-1",
    noteId: "n1",
    name: "Q4报告.pdf",
    mime: "application/pdf",
    size: 120_000,
    storage: "pvblob-v1",
    blobId: "abcdef0123456789",
    chunks: 2,
  });
  expect(enriched.blobShort).toBe("blobs/abcd…6789.pvblob");
  expect(enriched.canExtractText).toBe(true);
  expect(enriched.blockedExternal).toBe(false);

  const item: Item = {
    id: "n1",
    type: "secureNote",
    title: "测试",
    uiMeta: { notes: { collapsed: true, accent: "blue" } },
  };
  expect(readItemMeta(item, "notes", { collapsed: false, accent: "gray" })).toEqual({
    collapsed: true,
    accent: "blue",
  });
  expect(readItemMeta(item, "missing", { mode: "edit" })).toEqual({ mode: "edit" });

  expect(readUiPref({ uiPrefs: { noteMode: "preview" } }, "noteMode", "edit")).toBe("preview");
  expect(readUiPref({}, "noteMode", "edit")).toBe("edit");
});

test("AI paired client view-model distinguishes duplicate names, aggregates telemetry, filters and prunes notes", () => {
  const now = 1_763_600_000;
  const views = buildAiClientViews(
    [
      { id: "c-u1", name: "本机 AI 客户端", fingerprint: "91f0…44e2", createdUnix: now - 50_000 },
      { id: "c-u2", name: "本机 AI 客户端", fingerprint: "3b8a…01c7", createdUnix: now - 90_000 },
      { id: "c-p1", name: "Claude Code", fingerprint: "7c1e…209a", paused: true, createdUnix: now - 200_000, callCount: 3, lastUsedUnix: now - 172_800, lastOp: "search" },
      { id: "c-a1", name: "Claude Code", fingerprint: "aadd…88b5", createdUnix: now - 30_000, callCount: 5, lastUsedUnix: now - 120, lastOp: "note_update" },
    ],
    [
      { client: "c-a1", operation: "note_update", result: "Allowed", unixSeconds: now - 120 },
      { client: "c-a1", operation: "search", result: "Allowed", unixSeconds: now - 600 },
      { client: "c-p1", operation: "search", result: "ClientPaused", unixSeconds: now - 60 },
    ],
    [{ client: "c-a1", entryId: "e1", field: "password" }],
    { "c-a1": "主开发终端", "c-p1": "旧工作区", "c-revoked": "stale" },
    now,
  );
  // Sorted: active -> paused -> unused
  expect(views.map((v) => v.id)).toEqual(["c-a1", "c-p1", "c-u1", "c-u2"]);
  expect(views[0].state).toBe("active");
  expect(views[0].hasLease).toBe(true);
  expect(views[0].calls24h).toBe(2);
  expect(views[0].callsTotal).toBe(5);
  expect(views[0].note).toBe("主开发终端");
  expect(views[1].state).toBe("paused");
  expect(views[2].state).toBe("unused");
  expect(clientStateLabel(views[0].state)).toBe("活跃");
  expect(clientSubline(views[2])).toContain("从未调用");

  expect(countAiClientStates(views)).toEqual({ total: 4, active: 1, paused: 1, unused: 2 });
  expect(findDuplicateClientNames(views)).toEqual([
    ["Claude Code", 2],
    ["本机 AI 客户端", 2],
  ]);

  expect(filterAiClients(views, "unused", "").length).toBe(2);
  expect(filterAiClients(views, "all", "7c1e").map((v) => v.id)).toEqual(["c-p1"]);
  expect(filterAiClients(views, "all", "主开发").map((v) => v.id)).toEqual(["c-a1"]);
  expect(aiError("Error: ClientPaused")).toBe(AI_ERRORS.ClientPaused);
  expect(pruneClientNotes({ "c-a1": "主开发终端", "c-revoked": "gone" }, ["c-a1"])).toEqual({ "c-a1": "主开发终端" });
});
