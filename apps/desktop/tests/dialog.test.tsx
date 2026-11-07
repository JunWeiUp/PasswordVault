import { expect, open, test } from "nsh/test";
test("settings and task dialogs can reopen after native dismissal", async () => {
  const app = await open("../ui/settings/DialogHarness.tsx", {width:1200,height:900,platform:"macos"});
  for (const label of ["打开设置测试", "打开弹窗测试"]) {
    for (let n=0;n<3;n++) {
      await app.press(`text:${label}`);
      await app.back();
      expect(app.texts()).not.toContain(label === "打开设置测试" ? "关闭" : "测试弹窗内容");
    }
  }
});
