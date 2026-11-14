// Synthetic-vault headless fixture; never imported by App.tsx.
import { mount, signal, View } from "nsh";
import { Btn, T } from "../kit";
import { call, edit, ensureFull, items, load, refreshItems, unlock } from "../store";
const ID = "relay-refresh-fixture";
const state = signal("");
const shown = () => items().find((i) => i.id === ID);
const describe = () => { const i = shown(); return i ? `${i.noteSummary ? "summary" : "full"}:${i.note}` : "missing"; };
const doc = (text: string) => ({ type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text }] }] });
const note = (text: string) => ({ id: ID, type: "secureNote" as const, title: "Refresh fixture", note: text, noteFormat: "rich-v1", noteDocument: doc(text), updatedAt: new Date().toISOString() });
mount(() => <View>
  <Btn label="准备" onPress={async () => { await unlock("synthetic-preview-password"); await call({ op: "save", item: note("original") }); await load(); await ensureFull(ID); state.set(`ready ${describe()}`); }} />
  <Btn label="同步刷新" onPress={async () => { await refreshItems(); state.set(`refreshed ${describe()}`); }} />
  <Btn label="本机编辑" onPress={() => { edit(ID, (d) => { d.note = "local draft"; d.noteDocument = doc("local draft"); }); state.set(`edited ${describe()}`); }} />
  <Btn label="远端修改" onPress={async () => { await new Promise((r) => setTimeout(r, 1100)); await call({ op: "save", item: note("remote change") }); state.set("remote saved"); }} />
  <T>{state()}</T>
</View>);
