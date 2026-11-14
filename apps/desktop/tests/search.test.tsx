import { expect, open, test } from "nsh/test";

test("expanded list search respects type, chips and trash scope and clears from the field", async () => {
  const app = await open("./search-harness.tsx", { width: 1100, height: 850, platform: "macos" });
  await app.waitFor("id:search");
  await app.type("id:search", "BILLING backup-user");
  await app.waitFor("text:1 个搜索结果");
  expect(app.texts()).toContain("主账号");
  expect(app.texts()).not.toContain("其他账号");
  expect(app.texts()).not.toContain("回收账号");
  await app.press("text:收藏");
  expect(app.texts()).toContain("主账号");
  await app.press("label:清除搜索");
  expect(app.value("id:search")).toBe("");
  await app.press("text:全部");
  await app.waitFor("text:2 个项目");
  await app.type("id:search", "no-match-fixture");
  await app.waitFor("text:没有匹配的项目");
  expect(app.texts()).toContain("当前选中 无");
  await app.press("id:show-trash");
  await app.type("id:search", "billing");
  await app.waitFor("text:回收账号");
  expect(app.texts()).not.toContain("主账号");
  await app.press("id:show-all");
  await app.type("id:search", "receipt.png");
  await app.waitFor("text:项目笔记");
  expect(app.texts()).toContain("1 个搜索结果");
});

test("Quick Access searches wallet details and note attachments and opens a matched note", async () => {
  const app = await open("./search-harness.tsx", { width: 1100, height: 850, platform: "macos" });
  await app.press("id:open-quick");
  await app.waitFor("id:quick-access");
  await app.type("id:quick-access", "ＦＩＸＴＵＲＥ holder");
  await app.waitFor("text:付款卡");
  await app.clear("id:quick-access");
  await app.type("id:quick-access", "receipt.png 发布计划");
  await app.waitFor("text:项目笔记");
  await app.submit("id:quick-access");
  await app.waitFor("text:当前选中 note");
  expect(app.texts()).toContain("全部笔记");
  expect(app.texts()).not.toContain("回收账号");
});
