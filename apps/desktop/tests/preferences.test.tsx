// Category rename, list sorting, clipboard/menu-bar preferences and the About page,
// against the synthetic vault from `examples/seed.rs`.
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

test("renames a note category from its context menu and keeps its notes", async () => {
  const app = await unlocked();
  await app.rightClick("text:旅行");
  const menu = (app.menu() ?? []).map((entry) => entry.label);
  expect(menu).toContain("重命名…");
  expect(menu).toContain("删除分类…");
  await app.chooseMenuItem("重命名…");
  await app.waitFor("id:category-rename");
  await app.clear("id:category-rename");
  await app.type("id:category-rename", "出行");
  await app.press("id:category-rename-confirm");
  await app.waitFor("text:出行");
  expect(app.texts()).not.toContain("旅行");
});

test("sorts the list by name and keeps the choice visible", async () => {
  const app = await unlocked();
  await app.waitFor("id:sort-menu");
  expect(app.texts()).toContain("最近修改");
  await app.press("id:sort-menu");
  const menu = (app.menu() ?? []).map((entry) => entry.label);
  expect(menu).toEqual(["最近修改", "名称 A–Z", "创建时间"]);
  await app.chooseMenuItem("名称 A–Z");
  await app.waitFor("text:名称 A–Z");
});

test("general settings offer clipboard duration and the menu bar icon; About copies safe diagnostics", async () => {
  const app = await unlocked();
  await app.press("text:设置");
  await app.waitFor("text:自动清除剪贴板");
  expect(app.texts()).toContain("在菜单栏显示图标");
  expect(app.texts()).toContain("30 秒");
  await app.press("text:关于");
  await app.waitFor("text:复制诊断信息");
  await app.press("id:copy-diagnostics");
  await app.waitFor("text:已复制诊断信息");
  const text = app.clipboard() ?? "";
  expect(text).toContain("PasswordVault ");
  expect(text).toContain("Platform: macOS");
  expect(text).not.toContain("/Users/");
  expect(text).not.toContain("@");
});
