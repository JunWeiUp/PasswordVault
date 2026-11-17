// Breach check, launch at login and capture protection settings. Native calls that
// would reach the network or change system state are replaced with stand-ins.
import { expect, open, test } from "nsh/test";

const PASSWORD = "synthetic-preview-password";
const LEAKED = "Spring2024"; // used by two synthetic accounts in examples/seed.rs
const PAD = "0000000000000000000000000000000000A:0\r\n";

async function unlocked(modules: Record<string, any>) {
  const app = await open("../App.tsx", { width: 1440, height: 960, platform: "macos", modules: { "passwordvault/native": modules } });
  await app.waitFor("text:PasswordVault 已锁定");
  await app.type("id:unlock-password", PASSWORD);
  await app.submit("id:unlock-password");
  await app.waitFor("id:sidebar");
  return app;
}

test("breach check reports exposed passwords using only the hash prefix", async () => {
  const digest = crypto.createHash("sha1").update(LEAKED).digest("hex").toUpperCase();
  const asked: string[] = [];
  const app = await unlocked({
    "Breach.range": (prefix: string) => {
      asked.push(prefix);
      return prefix === digest.slice(0, 5) ? `${PAD}${digest.slice(5)}:42\r\n` : PAD;
    },
  });
  await app.press("text:密码健康");
  await app.waitFor("text:已知泄露检查");
  await app.press("id:breach-start");
  await app.waitFor("text:2 个账号的密码出现在已知泄露中，请尽快更换。");
  expect(app.texts()).toContain("公司邮箱");
  expect(app.texts()).toContain("出现 42 次");
  // Only five-character uppercase hex prefixes leave the app; never a password.
  expect(asked.length > 0).toBe(true);
  for (const prefix of asked) expect(/^[0-9A-F]{5}$/.test(prefix)).toBe(true);
  expect(asked.some((p) => p.includes(LEAKED))).toBe(false);
});

test("a failed breach check never reads as safe", async () => {
  const app = await unlocked({ "Breach.range": () => { throw new Error("Network"); } });
  await app.press("text:密码健康");
  await app.waitFor("id:breach-start");
  await app.press("id:breach-start");
  await app.waitFor("text:本次未发现泄露记录，但部分检查未完成，未完成不代表安全。");
});

test("general and security settings show launch at login and capture protection", async () => {
  const app = await unlocked({ "LoginItem.status": "requiresApproval" });
  await app.press("text:设置");
  await app.waitFor("text:登录时启动");
  expect(app.texts()).toContain("需要系统批准");
  expect(app.texts()).toContain("打开登录项设置");
  await app.press("text:安全");
  await app.waitFor("text:截屏、录屏和屏幕共享时隐藏窗口");
});
