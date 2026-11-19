// End-to-end UI tests for pinned top AI 访问 entry and Paired AI Clients management.
import { expect, open, test } from "nsh/test";

const PASSWORD = "synthetic-preview-password";

async function unlocked() {
  const app = await open("../App.tsx", { width: 1440, height: 960, platform: "macos" });
  await app.waitFor("text:PasswordVault 已锁定");
  await app.type("id:unlock-password", PASSWORD);
  await app.submit("id:unlock-password");
  await app.waitFor("id:sidebar");
  return app;
}

test("AI 访问 stays pinned above 全部项目 and supports full paired-client management", async () => {
  const app = await unlocked();

  // 1. Verify AI 访问 renders above 密码库 / 全部项目 and stays clickable on short windows.
  const initialTexts = app.texts();
  const aiIdx = initialTexts.indexOf("AI 访问");
  const vaultIdx = initialTexts.indexOf("密码库");
  const allIdx = initialTexts.indexOf("全部项目");
  expect(aiIdx >= 0 && vaultIdx > aiIdx && allIdx > vaultIdx).toBe(true);

  await app.setViewport(1200, 720);
  await app.press("id:nav-notes");
  await app.wait(150);
  await app.press("id:nav-ai");
  await app.waitFor("id:ai-workspace-hero");
  await app.setViewport(1440, 960);
  await app.waitFor("id:ai-hero-client-strip");
  await app.waitFor("id:ai-paired-clients-card");

  // 2. Enable AI interface and open accounts scope.
  if (app.texts().includes("启用接口")) {
    await app.press("text:启用接口");
    await app.waitFor("text:停用接口");
  }

  // 3. Pair first client ("Claude Code" with remark "主开发终端") via real PairSheet.
  await app.press("id:ai-pair-client-btn");
  await app.waitFor("id:ai-pair-sheet");
  await app.type("id:ai-pair-note-input", "主开发终端");
  await app.press("id:ai-pair-copy-btn");
  await app.waitFor("text:完成");
  await app.press("text:完成");
  await app.waitFor("text:1 个已配对客户端");
  await app.waitFor("text:主开发终端");

  // Make the first client active by running a real trial search request.
  await app.press("text:试查范围条目摘要");
  await app.waitFor("text:活跃");

  // 4. Pair a SECOND client with the exact same name "Claude Code" -> triggers duplicate warning!
  await app.press("id:ai-pair-client-btn");
  await app.waitFor("id:ai-pair-sheet");
  await app.waitFor("text:当前已有同名客户端");
  await app.press("id:ai-pair-copy-btn");
  await app.waitFor("text:完成");
  await app.press("text:完成");
  await app.waitFor("text:2 个已配对客户端");
  await app.waitFor("text:1 组同名");
  await app.waitFor("id:ai-cleanup-unused-btn");

  // 5. Pair a third unused client ("本机 AI 客户端").
  await app.press("id:ai-pair-client-btn");
  await app.waitFor("id:ai-pair-sheet");
  await app.clear("id:ai-pair-name-input");
  await app.type("id:ai-pair-name-input", "本机 AI 客户端");
  await app.press("id:ai-pair-copy-btn");
  await app.waitFor("text:完成");
  await app.press("text:完成");
  await app.waitFor("text:3 个已配对客户端");

  // 6. Newly paired client auto-expands inline drawer -> test EditClientSheet (name + note) & Pause/Resume.
  await app.waitFor("id:ai-client-inline-drawer");
  await app.press("text:编辑名称与备注");
  await app.waitFor("id:ai-edit-client-sheet");
  await app.type("id:ai-edit-client-note", "测试终端");
  await app.press("id:ai-edit-client-save");
  await app.waitFor("text:测试终端");

  await app.press("text:暂停访问");
  await app.waitFor("text:已暂停");
  await app.press("text:恢复访问");
  await app.wait(250);

  // 7. Filter tabs: switch to 未使用 -> hides active 主开发终端; switch back to 全部.
  await app.press("id:ai-filter-unused");
  await app.wait(200);
  expect(app.texts()).not.toContain("主开发终端");
  expect(app.texts()).toContain("测试终端");
  await app.press("id:ai-filter-all");
  await app.waitFor("text:主开发终端");

  // 8. Open batch manager sheet from Hero strip.
  await app.press("id:ai-open-manager-btn");
  await app.waitFor("id:ai-clients-manager-sheet");
  await app.press("text:完成");
  await app.wait(200);

  // 9. One-click cleanup unused clients -> removes the 2 unused clients, leaving only active 主开发终端!
  await app.press("id:ai-cleanup-unused-btn");
  await app.waitFor("id:ai-cleanup-unused-sheet");
  await app.press("id:ai-cleanup-unused-confirm");
  await app.waitFor("text:1 个已配对客户端");
  expect(app.texts()).toContain("主开发终端");
  expect(app.texts()).not.toContain("测试终端");

  // 10. Clean up shared synthetic vault state so subsequent test suites start from clean defaults.
  await app.press("text:主开发终端");
  await app.waitFor("id:ai-client-inline-drawer");
  await app.press("text:撤销客户端");
  await app.waitFor("id:confirm-ok");
  await app.press("id:confirm-ok");
  await app.waitFor("text:暂无已配对客户端");
  await app.press("text:停用接口");
  await app.waitFor("text:启用接口");
});
