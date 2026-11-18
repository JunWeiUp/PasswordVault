// Synthetic group-panel fixture; no server operations or real credentials.
import { mount, signal, View } from "nsh";
import { GroupPanel } from "./GroupPanel";
import { exitNotice } from "./index";
import { Btn, SheetHost, T } from "../kit";
const result = signal(""), rejectExit = signal(false);
const group = signal<any>({ device: "mac", state: { name: "QA group", members: [
  { device: "mac", name: "Mac", manager: true }, { device: "phone", name: "Phone", manager: false, signing_key: "0123456789abcdef0123456789abcdef" },
] } });
mount(() => <View style={{ padding: 16 }}>
  <Btn label="显示对等库申请" onPress={() => group.set({ ...group(), peerLibrary: "lib", applicant: "Phone", code: "ABCD-1234-EF56" })} />
  <Btn label="显示个人组申请" onPress={() => group.set({ ...group(), invitationLink: "common-relay://fixture", invitationMode: "manual", applicant: "Phone", code: "ABCD-1234-EF56" })} />
  <Btn label="显示同步设备" onPress={() => group.set({ ...group(), device: "phone" })} />
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
