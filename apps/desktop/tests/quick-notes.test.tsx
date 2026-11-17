// Quick Access per-action shortcuts and "save note as Markdown / HTML".
// File panels and file writes are replaced with stand-ins; nothing touches disk.
import { expect, open, test } from "nsh/test";

const PASSWORD = "synthetic-preview-password";

async function unlocked(modules: Record<string, any> = {}) {
  const app = await open("../App.tsx", { width: 1440, height: 960, platform: "macos", modules: { "passwordvault/native": modules } });
  await app.waitFor("text:PasswordVault 已锁定");
  await app.type("id:unlock-password", PASSWORD);
  await app.submit("id:unlock-password");
  await app.waitFor("id:sidebar");
  return app;
}

test("Quick Access copies the username with mod+c and reveals the item with mod+enter", async () => {
  const app = await unlocked();
  await app.press("text:快速访问");
  await app.waitFor("id:quick-access");
  expect(app.texts()).toContain("⌘C 复制用户名");
  await app.type("id:quick-access", "Apple ID");
  await app.waitFor("text:Apple ID");
  await app.keyboard.press("mod+c");
  await app.waitFor("text:已复制用户名 · 30 秒后清除");
  expect(app.clipboard()).toBe("lin@example.com");

  await app.press("text:快速访问");
  await app.waitFor("id:quick-access");
  await app.type("id:quick-access", "家庭 Wi-Fi");
  await app.waitFor("text:家庭 Wi-Fi");
  await app.keyboard.press("mod+enter");
  await app.waitFor("text:Home-Example");
  expect(app.texts()).toContain("账号");
});

test("a note saves as Markdown and HTML only after confirming the unencrypted export", async () => {
  const writes: { path: string; contents: string }[] = [];
  const app = await unlocked({
    "Files.pickSave": (_title: string, name: string) => `/tmp/pv-export-fixture/${name}`,
    "Files.saveNoteExport": (path: string, contents: string) => { writes.push({ path, contents }); },
  });
  await app.waitFor("text:家庭重要资料");
  await app.press("text:家庭重要资料");
  await app.press("id:detail-more");
  await app.chooseMenuItem("另存为 Markdown…");
  await app.waitFor("text:导出的文件不加密，任何能访问该文件的人都能读取。附件和图片不会一起导出。");
  expect(writes.length).toBe(0);
  await app.press("text:选择保存位置…");
  await app.waitUntil(() => writes.length === 1);
  expect(writes[0].path).toBe("/tmp/pv-export-fixture/家庭重要资料.md");
  expect(writes[0].contents).toContain("紧急联系");

  await app.press("id:detail-more");
  await app.chooseMenuItem("另存为 HTML…");
  await app.press("text:选择保存位置…");
  await app.waitUntil(() => writes.length === 2);
  expect(writes[1].path).toBe("/tmp/pv-export-fixture/家庭重要资料.html");
  expect(writes[1].contents).toContain("<title>家庭重要资料</title>");
  expect(writes[1].contents).toContain("紧急联系");
});
