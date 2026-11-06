import { expect, open, test } from "nsh/test";
import { differingFields } from "../ui/history";

test("history difference includes removed and added fields", () => {
  expect(differingFields({ title: "a", password: "old", removed: 1 }, { title: "a", password: "new", added: 2 })).toEqual(["added", "password", "removed"]);
});
test("history hides secrets until explicit reveal and restore requires confirmation", async () => {
  const app = await open("../ui/recovery/TestHarness.tsx", { width: 1100, height: 1100, platform: "macos" });
  await app.press("text:准备测试库");
  await app.waitFor("text:准备历史条目");
  await app.press("text:准备历史条目");
  await app.waitFor("text:条目版本历史");
  await app.wait(300);
  expect(app.texts().some(s => s.includes("secret-before"))).toBe(false);
  const version = app.texts().find(s => s.includes("设备未记录"))!;
  expect(!!version).toBe(true);
  await app.press(`text:${version} >> nth=1`);
  expect(app.texts().some(s => s.includes("secret-before"))).toBe(false);
  await app.press("label:显示完整内容（包含敏感信息）");
  expect(app.texts().some(s => s.includes('"password"'))).toBe(true);
  await app.press("text:恢复此版本…");
  await app.waitFor("text:恢复所选版本？");
  await app.press("text:取消操作");
  await app.press("text:恢复此版本…");
  await app.press("text:确认恢复版本");
  await app.wait(400);
  await app.press("text:再次打开历史");
  await app.waitFor("text:3 / 3 个版本");
  expect(app.texts().some(s => s.includes('"password"'))).toBe(false);
  await app.press("text:清理旧版本…");
  await app.waitFor("text:清理此条目的旧版本？");
  await app.press("text:确认清理旧版本");
  await app.waitFor("text:1 / 1 个版本");
  expect(app.texts().some(s => s.includes('"password"'))).toBe(false);
});
