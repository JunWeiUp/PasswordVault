// Run on Windows against a fresh TEMP vault seeded by examples/seed.rs.
import { expect, open, test } from "nsh/test";
import { platform } from "os";
const windowsTest = platform() === "windows" ? test : test.skip;

windowsTest("Windows unlock, platform settings, dialog reopening and explicit lock", async () => {
  const app = await open("../App.tsx", { width: 1440, height: 960, platform: "windows" });
  await app.waitFor("text:PasswordVault 已锁定");
  expect(app.texts()).not.toContain("使用 Touch ID 解锁");
  await app.type("id:unlock-password", "wrong-password");
  await app.submit("id:unlock-password");
  await app.waitFor("text:主密码不正确，或加密数据已损坏。");
  await app.waitUntil(() => app.value("id:unlock-password") === "");
  await app.wait(300);
  await app.type("id:unlock-password", "synthetic-preview-password");
  await app.submit("id:unlock-password");
  await app.waitFor("id:sidebar");
  expect(app.texts()).toContain("家庭重要资料");
  await app.waitFor("id:note-rich-editor");
  expect(app.texts().some(t => t.includes("此笔记包含暂不支持"))).toBe(false);
  // Headless tests cannot draw. Native Windows runs retain this QA image.
  try { await app.screenshot("windows-qa-unlocked.png"); } catch {}
  await app.press("text:账号");
  await app.press("id:row-a1");
  await app.waitFor("text:lin.dev@example.com");
  const title = `Windows QA ${Math.random().toString(16).slice(2)}`;
  await app.press("id:new-item");
  await app.waitFor("text:完成");
  await app.clear("label:标题");
  await app.type("label:标题", title);
  await app.type("label:用户名", "windows-qa@example.test");
  await app.type("label:密码", "synthetic-Windows-qa-42");
  await app.press("text:完成");
  await app.waitFor("text:已加密保存");
  await app.press("text:笔记");
  await app.press("text:账号");
  await app.waitFor(`text:${title}`);
  await app.waitFor("text:windows-qa@example.test");
  await app.press("label:设置");
  await app.press("text:安全");
  expect(app.texts()).not.toContain("使用 Touch ID 解锁");
  await app.press("text:浏览器");
  await app.waitFor("text:Windows 浏览器连接尚未开放");
  await app.back();
  await app.press("label:设置");
  await app.press("text:AI 访问");
  await app.waitFor("text:Windows AI 访问尚未开放");
  await app.back();
  await app.press("id:lock");
  await app.waitFor("text:PasswordVault 已锁定");
  expect(app.texts()).not.toContain("lin.dev@example.com");
  expect(app.texts()).not.toContain("windows-qa@example.test");
}, 120000);

windowsTest("Windows rich editor preserves Chinese edits and legacy content", async () => {
  const app = await open("../ui/notes/TestHarness.tsx", { width: 900, height: 900, platform: "windows" });
  await app.waitFor("id:note-rich-editor");
  expect(app.texts()).toContain("saves:0");
  await app.type("id:note-rich-editor", "中文追加");
  await app.waitUntil(() => app.texts().some(t => t.includes('"noteFormat":"rich-v1"') && t.includes('"source":"original"') && t.includes("中文追加")));
}, 60000);
