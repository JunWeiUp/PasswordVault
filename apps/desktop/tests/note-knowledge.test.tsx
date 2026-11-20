// Obsidian-style personal knowledge base UI & pure helper tests against the synthetic vault.
import { expect, open, test } from "nsh/test";
import {
  buildCatTree,
  catLeaf,
  catMatches,
  diffLines,
  diffNoteProperties,
  diffStats,
  extractWikilinks,
  findNoteBacklinks,
  isAiWritableCategory,
} from "../ui/notes/knowledge";

const PASSWORD = "synthetic-preview-password";

async function unlocked() {
  const app = await open("../App.tsx", { width: 1440, height: 960, platform: "macos" });
  await app.waitFor("text:PasswordVault 已锁定");
  await app.type("id:unlock-password", PASSWORD);
  await app.submit("id:unlock-password");
  await app.waitFor("id:sidebar");
  return app;
}

test("pure knowledge-base helpers handle hierarchical folders, wikilinks, backlinks and diff", () => {
  expect(catMatches("资产/持仓/美股", "资产")).toBe(true);
  expect(catMatches("资产/持仓", "资产/持仓")).toBe(true);
  expect(catMatches("资产管理", "资产")).toBe(false);
  expect(catLeaf("资产/持仓")).toBe("持仓");

  const tree = buildCatTree(["资产/持仓", "资产/现金", "健康/体检"], {});
  expect(tree.map((n) => `${n.depth}:${n.path}`)).toEqual([
    "0:健康",
    "1:健康/体检",
    "0:资产",
    "1:资产/持仓",
    "1:资产/现金",
  ]);
  const folded = buildCatTree(["资产/持仓", "资产/现金"], { 资产: true });
  expect(folded.map((n) => n.path)).toEqual(["资产"]);

  expect(
    isAiWritableCategory("资产/持仓/美股", {
      aiAccessEnabled: true,
      aiAccessScopes: { notes: true },
      aiAccessNoteAutoWrite: true,
      aiAccessNoteWritableCategories: ["资产/持仓"],
    }),
  ).toBe(true);
  expect(
    isAiWritableCategory("家庭", {
      aiAccessEnabled: true,
      aiAccessScopes: { notes: true },
      aiAccessNoteAutoWrite: true,
      aiAccessNoteWritableCategories: ["资产/持仓"],
    }),
  ).toBe(false);

  expect(extractWikilinks("参见 [[年度复盘]] 与 [[2026 体检记录]]，再引用 [[年度复盘]]")).toEqual([
    "年度复盘",
    "2026 体检记录",
  ]);

  const target = { id: "a", type: "secureNote" as const, title: "年度复盘", note: "" };
  const other = { id: "b", type: "secureNote" as const, title: "持仓总览", note: "- 联动 [[年度复盘]]" };
  const refs = findNoteBacklinks(target, [target, other]);
  expect(refs.length).toBe(1);
  expect(refs[0].item.id).toBe("b");

  const d = diffLines("## 持仓\n- AAPL 100", "## 持仓\n- AAPL 120\n- NVDA 50");
  expect(d.some((l) => l.type === "del" && l.text.includes("100"))).toBe(true);
  expect(d.some((l) => l.type === "add" && l.text.includes("NVDA"))).toBe(true);
  expect(diffStats("a\nb", "a\nc\nd")).toEqual({ add: 2, del: 1 });

  const pd = diffNoteProperties(
    [{ key: "基准币种", value: "USD" }, { key: "旧字段", value: "1" }],
    [{ key: "基准币种", value: "CNY" }, { key: "风险", value: "中" }],
  );
  expect(pd.map((r) => `${r.key}:${r.kind}`)).toEqual(["基准币种:changed", "旧字段:removed", "风险:added"]);
});

test("notes support hierarchical folders, properties/slug, MD wikilinks/backlinks and milestone diff history", async () => {
  const app = await unlocked();
  await app.waitFor("id:add-category");

  // 1. Add hierarchical folder 资产/持仓
  await app.press("id:add-category");
  await app.waitFor("id:category-add-input");
  await app.type("id:category-add-input", "资产/持仓");
  await app.press("id:category-add-confirm");
  await app.waitFor("id:cat-资产");
  await app.waitFor("id:cat-资产/持仓");

  // 2. Return to 全部笔记 and select 家庭重要资料
  await app.press("id:nav-notes");
  await app.waitFor("id:note-properties-panel");
  await app.waitFor("id:note-assets-section");
  expect(app.texts().some((t) => t.includes("加密资产附件"))).toBe(true);

  // Verify editor line numbers show by default, toggle off/on from toolbar, sync with MD mode and more menu.
  await app.waitFor("id:note-line-gutter");
  await app.waitFor("id:note-line-num-1");
  await app.press("id:note-line-numbers-toggle");
  await app.waitFor("id:note-line-gutter", { state: "gone" });
  await app.press("id:note-mode-md");
  await app.waitFor("id:md-line-numbers-toggle");
  await app.press("id:md-line-numbers-toggle");
  await app.press("id:note-mode-edit");
  await app.waitFor("id:note-line-gutter");
  await app.waitFor("id:note-line-num-1");
  await app.press("id:detail-more");
  expect((app.menu() ?? []).some((m) => m.label === "显示行号" && m.checked === true)).toBe(true);
  await app.chooseMenuItem("显示行号");
  await app.waitFor("id:note-line-gutter", { state: "gone" });
  await app.press("id:note-line-numbers-toggle");
  await app.waitFor("id:note-line-gutter");

  // Add slug & structured property
  await app.type("id:note-slug-input", "family-guide");
  await app.submit("id:note-slug-input");
  await app.press("text:添加属性");
  await app.waitFor("id:note-prop-key");
  await app.type("id:note-prop-key", "更新频率");
  await app.type("id:note-prop-value", "季度");
  await app.press("id:note-prop-add-confirm");
  await app.waitFor("text:更新频率");

  // 3. Switch to MD mode, add a [[旅行准备清单]] wikilink, apply & verify outgoing + backlink
  await app.press("id:note-mode-md");
  await app.waitFor("id:note-markdown-input");
  await app.type("id:note-markdown-input", "\n\n关联参考：[[旅行准备清单]]");
  await app.press("id:md-apply-btn");
  await app.waitFor("id:note-links-section");
  expect(app.texts()).toContain("[[旅行准备清单]]");

  // Click the outgoing wikilink to jump to 旅行准备清单 and see incoming backlink
  await app.press("text:[[旅行准备清单]]");
  await app.waitFor("text:反向链接（1）");
  expect(app.texts()).toContain("家庭重要资料");

  // 4. Open dedicated note version history modal, save milestone, inspect diff & preview
  await app.press("id:note-history-btn");
  await app.waitFor("id:note-history-sheet");
  await app.press("id:history-inline-milestone-btn");
  await app.waitFor("id:history-milestone-input");
  await app.type("id:history-milestone-input", "首次里程碑归档");
  await app.press("id:history-milestone-submit");
  await app.waitFor("text:首次里程碑归档");
  await app.press("id:history-mode-preview");
  await app.waitFor("text:复制此版本 Markdown");
  await app.press("id:history-mode-props");
  await app.waitFor("text:字段 / 属性");
  await app.press("text:关闭");

  // 5. Open AI Workspace, check Option A + asset MCP tools, add writable category & verify exclusion sheet
  await app.press("id:nav-ai");
  await app.waitFor("text:个人知识库 · AI 免弹窗自动保存与资产归档");
  for (const tool of ["find", "read", "create", "update", "delete"]) expect(app.texts()).toContain(tool);
  if (app.texts().includes("启用接口")) {
    await app.press("text:启用接口");
    await app.waitFor("text:停用接口");
  }
  await app.press("id:ai-manage-excluded-btn");
  await app.waitFor("id:ai-excluded-entries-sheet");
  await app.press("text:完成");
  await app.press("label:笔记 >> nth=1");
  await app.waitFor("text:AI 每次写入或归档附件都必须提供变更摘要（summary），并自动记录加密版本历史。");
  await app.press("id:ai-manage-writable-btn");
  await app.waitFor("id:ai-writable-custom-input");
  await app.type("id:ai-writable-custom-input", "自动注册目录");
  await app.press("id:ai-writable-custom-add");
  await app.waitFor("text:已允许 AI 自动保存「自动注册目录」目录");
  await app.press("text:完成");
  await app.waitFor("text:自动注册目录");
  await app.press("id:nav-notes");
  await app.waitFor("id:cat-自动注册目录");
});
