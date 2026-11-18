import { expect, open, test } from "nsh/test";
import { shouldOfferBiometrics } from "../ui/biometric-offer";
test("Touch ID is offered after creating a vault only on a Mac with available, unenrolled biometrics", () => {
  const base = { mac: true, available: true, enabled: false, restoring: false };
  expect(shouldOfferBiometrics(base)).toBe(true);
  expect(shouldOfferBiometrics({ ...base, mac: false })).toBe(false);
  expect(shouldOfferBiometrics({ ...base, available: false })).toBe(false);
  expect(shouldOfferBiometrics({ ...base, enabled: true })).toBe(false);
  expect(shouldOfferBiometrics({ ...base, restoring: true })).toBe(false);
});
test("the first-run Touch ID offer can be postponed and reports failures without enabling", async () => {
  const app = await open("./biometric-harness.tsx", { width: 800, height: 600, platform: "macos" });
  await app.press("text:显示 Touch ID 提示");
  await app.waitFor("text:使用 Touch ID 解锁？");
  await app.press("text:启用 Touch ID");
  await app.waitFor("text:Touch ID 操作未完成，请重试或使用主密码。");
  expect(app.texts()).toContain("使用 Touch ID 解锁？");
  await app.press("text:稍后在设置中启用");
  await app.waitUntil(() => !app.texts().includes("使用 Touch ID 解锁？"));
});
