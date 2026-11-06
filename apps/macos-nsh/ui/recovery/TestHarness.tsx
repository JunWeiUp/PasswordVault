// Synthetic-vault headless fixture; never imported by App.tsx.
import { mount, signal, View } from "nsh";
import { RecoverySettings, askRecoveryReset } from "./index";
import { call, items, load, lock, unlock } from "../store";
import { Btn, SheetHost, T } from "../kit";
import { openItemHistory } from "../history";
const ready = signal(false), message = signal("");
async function prepare() {
  try { await unlock("synthetic-preview-password"); ready.set(true); } catch (e) { message.set(String(e)); }
}
mount(() => <View><Btn label="准备测试库" onPress={prepare} /><T>{message()}</T>
  <If when={ready()}><RecoverySettings />
    <Btn label="锁定并恢复" onPress={async () => { await lock(); askRecoveryReset(); }} />
    <Btn label="再次打开历史" onPress={() => { const item = items().find(i => i.id === "nsh-history-fixture"); if (item) openItemHistory(item); }} />
    <Btn label="准备历史条目" onPress={async () => {
      await call({ op: "history-enable" });
      const item = { id: "nsh-history-fixture", type: "password" as const, title: "History fixture", password: "secret-before", updatedAt: new Date().toISOString() };
      await call({ op: "save", item });
      await call({ op: "save", item: { ...item, password: "secret-after", updatedAt: new Date().toISOString() } });
      await load(); openItemHistory(item);
    }} />
  </If><SheetHost /></View>);
