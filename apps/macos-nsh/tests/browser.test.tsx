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
