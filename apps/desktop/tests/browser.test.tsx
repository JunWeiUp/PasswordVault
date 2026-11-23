import { expect, open, test } from "nsh/test";
test("browser page explains offline ownership and confirms revocation", async () => {
  const app = await open("../ui/browser/TestHarness.tsx", { width: 1100, height: 1200, platform: "macos" });
  await app.waitFor("text:浏览器");
  expect(app.texts()).toContain("待同步的离线保存");
  expect(app.texts()).toContain("尚无已配对插件。在扩展中选择「连接 Mac」后在这里确认。");
  await app.press("text:撤销全部后台授权");
  await app.waitFor("text:撤销后台授权？");
  expect(app.texts()).toContain("后台保存、读取与启动自动解锁将全部停用。");
  await app.press("text:取消");
});
test("passkey prompt requires a shown credential and the master password", async () => {
  const app = await open("../ui/browser/PasskeyHarness.tsx", { width: 900, height: 900, platform: "macos" });
  await app.waitFor("text:使用通行密钥登录？");
  expect(app.texts()).toContain("请选择一个通行密钥。");
  await app.type("label:当前主密码", "synthetic-only");
  // Without a selection the confirm button stays disabled and nothing is answered.
  expect(app.texts()).toContain("answer:");
  await app.press("text:bob");
  await app.waitFor("text:example.com · 共享资料库 · 已选择");
  await app.press("text:登录");
  await app.waitFor("text:answer:{\"currentPassword\":\"synthetic-only\",\"credentialId\":\"k2\",\"itemId\":\"i2\",\"library\":\"shared\"}");
});
