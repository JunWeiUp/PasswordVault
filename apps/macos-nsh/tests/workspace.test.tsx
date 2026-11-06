// Interface checks against the synthetic vault from `examples/seed.rs`
// (PASSWORDVAULT_VAULT_DIRECTORY must point at a fresh copy of it).
import { expect, open, test } from "nsh/test";

const PASSWORD = "synthetic-preview-password";
// Real-window runs (`--target macos`) save pictures here; headless runs cannot draw and skip it.
const SHOTS = "/tmp/pv-nsh-shots";
async function shot(app: { screenshot(path: string): Promise<unknown> }, name: string) {
  try {
    await app.screenshot(`${SHOTS}/${name}.png`);
  } catch {}
}

async function unlocked() {
  const app = await open("../App.tsx", { width: 1440, height: 960, platform: "macos" });
  await app.waitFor("text:PasswordVault 已锁定");
  await app.type("id:unlock-password", "wrong-password");
  await app.submit("id:unlock-password");
  await app.waitFor("text:主密码不正确，或加密数据已损坏。");
  await shot(app, "01-locked-error");
  await app.waitUntil(() => app.value("id:unlock-password") === "");
  // Let the native field settle after the app cleared it before typing again.
  await app.wait(300);
  await app.type("id:unlock-password", PASSWORD);
  if (app.value("id:unlock-password") !== PASSWORD) {
    await app.clear("id:unlock-password");
    await app.type("id:unlock-password", PASSWORD);
  }
  await app.submit("id:unlock-password");
  await app.waitFor("id:sidebar");
  return app;
}

test("unlocks and browses every destination", async () => {
  const app = await unlocked();
  expect(app.texts()).toContain("全部笔记");
  expect(app.texts()).toContain("家庭重要资料");
  await shot(app, "02-notes");

  await app.press("text:账号");
  await app.waitFor("text:lin.dev@example.com");
  expect(app.texts()).toContain("GitHub");
  await shot(app, "03-account");

  await app.press("text:验证码");
  await app.waitFor("text:Cloudflare");
  await shot(app, "04-codes");

  await app.press("text:钱包");
  await app.waitFor("text:示例信用卡");
  await shot(app, "05-wallet");

  await app.press("text:密码健康");
  await app.waitFor("text:重复使用");
  await shot(app, "06-health");

  await app.press("text:密码生成器");
  await app.waitFor("text:在本机生成，不联网，不自动保存。");
  await shot(app, "07-generator");

  await app.press("text:回收站");
  await app.waitFor("text:旧论坛账号");
  await shot(app, "08-trash");

  await app.press("text:设备与服务");
  await app.waitFor("text:新增设备");
  await shot(app, "11-devices");
  // A short window: the sidebar scrolls instead of overlapping its pinned footer.
  await app.setViewport(1200, 800);
  await app.press("text:笔记");
  await app.wait(400);
  await shot(app, "11b-short-window");
  await app.setViewport(1440, 960);

  await app.press("label:设置");
  await app.press("text:备份与导入");
  await app.waitFor("text:本机加密备份");
  await shot(app, "10-settings-backup");
  for (const [tab, name] of [["同步与设备", "12-settings-relay"], ["浏览器", "13-settings-browser"], ["AI 访问", "14-settings-ai"], ["通用", "15-settings-general"]]) {
    await app.press(`text:${tab}`);
    await app.wait(400);
    await shot(app, name);
  }
});

test("creates, edits, trashes and restores an account", async () => {
  const app = await unlocked();
  await app.press("text:账号");
  await app.press("id:new-item");
  await app.waitFor("text:完成");
  await app.clear("label:标题");
  await app.type("label:标题", "Synthetic Shop");
  await app.type("label:用户名", "shopper@example.com");
  await app.wait(800);
  await app.press("text:完成");
  await app.waitFor("text:已加密保存");
  expect(app.texts()).toContain("Synthetic Shop");
  await shot(app, "09-created");

  await app.press("label:更多操作");
  expect(app.menu()?.map((m) => m.label)).toContain("移到回收站…");
  await app.chooseMenuItem("移到回收站…");
  await app.press("text:移到回收站");
  await app.waitFor("text:已移到回收站，可随时恢复");
  await app.press("text:回收站");
  await app.waitFor("text:Synthetic Shop");
  await app.press("id:restore");
  await app.waitFor("text:lin.dev@example.com");
});

test("locks and forgets decrypted content", async () => {
  const app = await unlocked();
  await app.press("id:lock");
  await app.waitFor("text:PasswordVault 已锁定");
  expect(app.texts()).not.toContain("家庭重要资料");
});
