// The codes page against a stand-in host app: no vault, secrets or clipboard access in JS.
import { expect, open, test } from "nsh/test";

const ROWS = [
  { id: "c1", title: "GitHub", username: "lin@example.com", code: "159432", period: 30, remaining: 4 },
  { id: "c2", title: "Cloudflare", username: "ops@example.com", code: "123456", period: 30, remaining: 22 },
];

test("shows live codes and asks the host to copy or open them", async () => {
  const app = await open("../App.tsx", {
    width: 390, height: 844, platform: "ios",
    host: { handlers: { "vault.codes": { codes: ROWS }, "clipboard.copy": null, "vault.open": null } },
  });
  await app.waitFor("text:验证码");
  await app.waitFor("text:159 432");
  expect(app.texts()).toContain("GitHub");
  expect(app.texts()).toContain("123 456");
  expect(app.texts()).toContain("4");

  await app.press("id:code-c1");
  await app.waitUntil(() => app.host.calls().some((m) => m.name === "clipboard.copy"));
  const copy = app.host.calls().find((m) => m.name === "clipboard.copy")!;
  expect(copy.data).toEqual({ text: "159432", label: "验证码" });

  await app.press("label:查看详情 >> nth=0");
  await app.waitUntil(() => app.host.calls().some((m) => m.name === "vault.open"));
  expect(app.host.calls().find((m) => m.name === "vault.open")!.data).toEqual({ id: "c1" });
});

test("an empty vault and a failing host are both explained", async () => {
  const empty = await open("../App.tsx", { width: 390, height: 844, platform: "ios", host: { handlers: { "vault.codes": { codes: [] } } } });
  await empty.waitFor("text:还没有验证码。可在右上角添加。");
  const failing = await open("../App.tsx", { width: 390, height: 844, platform: "ios", host: { handlers: { "vault.codes": () => { throw new Error("Locked"); } } } });
  await failing.waitFor("text:无法读取验证码，请稍后重试。");
});
