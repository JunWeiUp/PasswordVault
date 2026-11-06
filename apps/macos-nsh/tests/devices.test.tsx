import { expect, open, test } from "nsh/test";
import { blankDevice, connectionCommand, deviceSearchText, importedDevice, planDeviceImport } from "../ui/devices/model";
import type { Item } from "../ui/store";

test("device imports preserve exact secret text and explicitly skip prior and selected duplicates", () => {
  const script = { id: "source-a", name: "示例北区-后台.command", text: "#!/bin/sh\r\nssh $HOST\r\n", size: 24 };
  const token = { id: "source-b", name: "示例北区-令牌.txt", text: "SYNTHETIC_TOKEN\n", size: 16 };
  const node = { id: "source-c", name: "示例南区-节点.txt", text: "vless://SYNTHETIC_NODE@example.test:443\n", size: 41 };
  const plan = planDeviceImport([script, token, node, { ...script, id: "selected-twice" }], []);
  expect(plan.groups.map(g => g.title)).toEqual(["示例北区", "示例南区"]);
  expect(plan.skipped).toEqual([script.name]);
  const data = importedDevice(plan.groups[0].documents);
  expect(data.commands.map(c => c.text)).toEqual([script.text, token.text]);
  expect(data.commands.every(c => c.secret)).toBe(true);
  expect(data.host).toBe(""); expect(data.services.length).toBe(0);
  const existing = [{ id: "existing", type: "device", title: "Renamed", isDeleted: false, device: data }] as Item[];
  expect(planDeviceImport([script, token], existing).groups.length).toBe(0);
  expect(planDeviceImport([script, token], existing).skipped.length).toBe(2);
  const deleted = existing.map(i => ({ ...i, isDeleted: true }));
  const reimport = planDeviceImport([script, token], deleted);
  expect(reimport.groups.length).toBe(1);
  expect(reimport.groups[0].documents.map(d => d.text)).toEqual([script.text, token.text]);
  expect(reimport.skipped.length).toBe(0);
  expect(deleted[0].isDeleted).toBe(true);
  expect(planDeviceImport([script, token], [...deleted, ...existing]).skipped.length).toBe(2);
  expect(planDeviceImport([{ ...script, id: "changed", text: "new content" }], existing).groups.length).toBe(1);
});

test("device import previews before creating and repeated import does not duplicate records", async () => {
  const app = await open("../ui/devices/TestHarness.tsx", { width: 1100, height: 1500, platform: "macos" });
  await app.press("text:准备设备导入测试库");
  await app.waitFor("text:打开合成资料导入");
  await app.press("text:打开合成资料导入");
  await app.press("text:选择资料文件…");
  await app.waitFor("text:预览：新增 2 台设备 · 3 条敏感资料");
  expect(app.texts()).toContain("设备数量：0");
  expect(app.texts().some(t => t.includes("SYNTHETIC_TOKEN"))).toBe(false);
  await app.press("text:取消");
  expect(app.texts()).toContain("设备数量：0");
  await app.press("text:打开合成资料导入");
  await app.press("text:选择资料文件…");
  await app.waitFor("text:预览：新增 2 台设备 · 3 条敏感资料");
  await app.press("text:确认新增设备");
  await app.waitFor("text:已新增 2 台设备");
  expect(app.texts()).toContain("设备数量：2");
  expect(app.texts()).toContain("敏感资料数量：3");
  await app.press("text:完成");
  await app.waitFor("text:脚本与资料");
  expect(app.texts().includes("概览")).toBe(false);
  expect(app.texts().includes("文件")).toBe(false);
  await app.waitFor("text:资料目录");
  await app.press("text:AI 访问");
  await app.waitFor("text:打开 AI 访问设置");

  await app.press("text:打开合成资料导入");
  await app.press("text:选择资料文件…");
  await app.waitFor("text:已跳过 3 个重复文件");
  expect(app.texts()).toContain("预览：新增 0 台设备 · 0 条敏感资料");
  await app.press("text:取消");
  await app.press("text:将合成设备移入回收站");
  await app.wait(300);
  await app.press("text:打开合成资料导入");
  await app.press("text:选择资料文件…");
  await app.waitFor("text:预览：新增 2 台设备 · 3 条敏感资料");
  await app.press("text:确认新增设备");
  await app.waitFor("text:已新增 2 台设备");
  expect(app.texts()).toContain("设备数量：4");
  await app.press("text:完成");
  expect(app.texts()).toContain("设备数量：4");
});

test("device connection commands quote untrusted hosts and never embed secrets", () => {
  const d = { ...blankDevice(), host: "host'; echo UNTRUSTED", username: "admin", password: "PASSWORD_CANARY", privateKey: "KEY_CANARY" };
  const command = connectionCommand(d);
  expect(command).toEqual(`ssh -p 22 -- 'admin@host'"'"'; echo UNTRUSTED'`);
  expect(command.includes("PASSWORD_CANARY")).toBe(false);
  expect(command.includes("KEY_CANARY")).toBe(false);
});

test("device search excludes sensitive notes commands files and service paths", () => {
  const data = { ...blankDevice(), host: "lab.example.com", aliases: ["studio"], notes: "SECRET_NOTE", password: "SECRET_PASSWORD",
    commands: [{ id: "c", title: "Instructions", text: "SECRET_COMMAND", secret: true }],
    services: [{ id: "s", name: "Browser", kind: "browser", path: "SECRET_PATH", localPort: 9222, remotePort: 9222 }],
    files: [{ name: "SECRET_FILENAME", attachmentId: "a", mime: "text/plain", size: 1 }] };
  const text = deviceSearchText({ id: "d", type: "device", title: "Lab", tags: ["work"], device: data } as Item);
  expect(text.includes("lab.example.com")).toBe(true);
  expect(text.includes("studio")).toBe(true);
  expect(text.includes("browser")).toBe(true);
  expect(text.includes("secret")).toBe(false);
});

test("document editor opens full Python text and preserves full filenames", async () => {
  const app = await open("../ui/devices/EditorHarness.tsx", { width: 640, height: 900, platform: "macos" });
  expect(app.texts()).toContain("示例设备-用于检查完整长标题显示的自动备份与健康检查脚本.py");

  await app.waitFor("label:资料正文");
  await app.press("text:系统终端 ▾");
  await app.waitFor("text:首选终端");
  await app.press("text:系统终端 · 当前首选");
  await app.press("text:点击运行");
  expect(app.texts()).toContain("已请求终端运行");
  expect(app.value("label:资料正文")).toBe("#!/usr/bin/env python3\n    print('SYNTHETIC_ONLY')\n");
  await app.clear("label:资料正文");
  await app.type("label:资料正文", "print('updated')");
  await app.press("text:收起内容");
  await app.press("text:显示内容");
  expect(app.value("label:资料正文")).toBe("print('updated')");
  await app.press("label:打开 配置.json");
  expect(app.value("label:资料正文")).toBe("{}");
  expect(app.texts().includes("点击运行")).toBe(false);
  await app.press("label:打开 示例设备-用于检查完整长标题显示的自动备份与健康检查脚本.py");
  expect(app.value("label:资料正文")).toBe("print('updated')");
  await app.press("text:新建资料");
  expect(app.value("label:资料正文")).toBe("");
  await app.setViewport(1100, 900);
  expect(app.texts()).toContain("资料目录");

});
