// Synthetic import UI fixture. Only used by the isolated headless test runner.
import { mount, signal, Scroll, View } from "nsh";
import { Btn, SheetHost, T, openSheet } from "../kit";
import { boot, call, items, phase, unlock } from "../store";
import { DeviceDetail, DeviceImport } from "./index";
const ready = signal(false), failure = signal("");
const documents = [
  { id: "device-import-fixture-north-script", name: "示例北区-控制台.command", text: "#!/bin/sh\necho SYNTHETIC_SCRIPT\n", size: 36 },
  { id: "device-import-fixture-north-token", name: "示例北区-令牌.txt", text: "SYNTHETIC_TOKEN\n", size: 16 },
  { id: "device-import-fixture-south-node", name: "示例南区-节点.txt", text: "vless://SYNTHETIC_NODE@example.test:443\n", size: 41 },
];
mount(() => <View style={{ padding: 16, gap: 12 }}>
  <Btn label="准备设备导入测试库" onPress={async () => {
    try {
      await boot(); await unlock("synthetic-preview-password");
      const status = await call({ op: "devices-status" });
      if (!status.enabled) await call({ op: "devices-enable", currentPassword: "synthetic-preview-password", confirm: true });
      ready.set(true);
    } catch (e) { failure.set(String(e)); }
  }} />
  <If when={ready() && phase() === "unlocked"}><Btn label="打开合成资料导入" onPress={() => openSheet({ width: 720, render: close => <DeviceImport close={close} pick={async () => documents.map(d => ({ ...d, id: crypto.randomUUID() }))} /> })} /></If>
  <T>{failure()}</T>
  <T>设备数量：{items().filter(i => i.type === "device").length}</T>
  <T>敏感资料数量：{items().filter(i => i.type === "device").flatMap(i => i.device.commands).filter(c => c.secret).length}</T>
  <Scroll style={{ height: 700 }}><View style={{ maxWidth: 860 }}><If when={items().some(i => i.type === "device")}><DeviceDetail item={items().find(i => i.type === "device")!} editable /></If></View></Scroll>
  <Btn label="将合成设备移入回收站" onPress={async () => {
    for (const item of items().filter(i => i.type === "device" && !i.isDeleted)) {
      const deleted = { ...item, isDeleted: true };
      await call({ op: "save", item: deleted });
      items.update(list => list.map(i => i.id === item.id ? deleted : i));
    }
  }} />
  <SheetHost />
</View>);
