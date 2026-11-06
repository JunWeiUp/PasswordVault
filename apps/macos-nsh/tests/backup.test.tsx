import { expect, open, test } from "nsh/test";

test("backup page separates local export, remote credentials and reviewed imports",async()=>{
  const app=await open("../ui/settings/backup-TestHarness.tsx",{width:1000,height:1200,platform:"macos"});
  await app.waitFor("text:备份与导入");
  expect(app.texts()).toContain("本机加密备份");
  expect(app.texts()).toContain("从其他密码管理器导入");
  expect(app.texts()).toContain("连接后查看备份");
  await app.press("text:导出…");
  await app.waitFor("text:导出加密备份");
  expect(app.texts()).toContain("单独保管备份密码");
  await app.press("text:取消");
  await app.waitFor("text:立即备份…");
  await app.press("text:立即备份…");
  await app.waitFor("text:上传完整加密备份");
  expect(app.texts()).toContain("使用新的唯一文件名，不覆盖远端已有备份。");
});
