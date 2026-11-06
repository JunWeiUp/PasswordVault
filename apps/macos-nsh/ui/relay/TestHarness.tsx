import { mount, View, signal } from "nsh";
import { Btn, SheetHost, T } from "../kit";
import { boot, unlock, phase, lock, call, load } from "../store";
import { RelayPage, syncStatus, refreshRelay } from "./index";
export default function App() {
  const devicesReady = signal(false);
  return <View style={{ padding: 16 }}>
    <Btn label="准备中继测试库" onPress={async () => { await boot(); await unlock("synthetic-preview-password"); }} />
    <Btn label="锁定测试库" onPress={() => void lock()} />
    <Btn label="启用格式 7 测试" onPress={async () => { await call({ op: "devices-enable", currentPassword: "synthetic-preview-password", confirm: true }); await load(); await refreshRelay(); devicesReady.set(true); }} />
    <If when={devicesReady()}><T>格式 7 测试已准备</T></If>
    <T>{syncStatus()}</T>
    <If when={phase() === "unlocked"}><RelayPage /></If>
    <SheetHost />
  </View>;
}

mount(App);
