// Synthetic group-panel fixture; no server operations or real credentials.
import { mount, signal, View } from "nsh";
import { GroupPanel } from "./GroupPanel";
import { exitNotice } from "./index";
import { Btn, SheetHost, T } from "../kit";
const result = signal(""), rejectExit = signal(false);
const group = signal<any>({ device: "mac", role: "hub", primaryDevice: "mac", primaryName: "Mac", isPrimary: true, state: { name: "QA group", members: [
  { device: "mac", name: "Mac", manager: true }, { device: "phone", name: "Phone", manager: false },
] } });
mount(() => <View style={{ padding: 16 }}>
  <Btn label="显示手动申请" onPress={() => group.set({ ...group(), applicant: "Phone", code: "ABCD-1234-EF56" })} />
  <Btn label="显示同步设备" onPress={() => group.set({ ...group(), device: "phone", role: "mobile", isPrimary: false })} />
  <Btn label="显示未入组" onPress={() => group.set({ device: "mac", role: "hub" })} />
  <Btn label="模拟本地写入失败" onPress={() => rejectExit.set(true)} />
  <GroupPanel group={group()} busy={false} act={async (request) => {
    if (request.op === "leave" || request.op === "disband") {
      if ("currentPassword" in request) throw new Error("UnexpectedPassword");
      if (rejectExit()) throw new Error("Storage");
    }
    result.set(`ACTION:${request.op}:${request.mode ?? request.code ?? (request.relayPassword ? "with-password" : "")}`);
  }} />
  <Btn label="模拟服务器解散失败" onPress={() => result.set(exitNotice({ disband: true, remote: "failed" }))} />
  <T>{result()}</T><SheetHost />
</View>);
