// Test-only harness for the identity document section (synthetic vault only).
import { mount, signal, View, Scroll } from "nsh";
import { IdentityDocument } from "./IdentityDocument";
import { CustomFields } from "./shared";
import { isDocumentField } from "./documents";
import { Btn, SheetHost, T } from "../kit";
import { items, unlock, createItem, flush, load } from "../store";
const ready = signal(false), editing = signal(true), error = signal("");
const item = () => items().find((i) => i.id === "identity-fixture");
const field = (id: string) => (item()?.customFields ?? []).find((f: any) => f.id === id);
function checks() {
  const n = field("document.number"), d = field("document.expiryDate"), legacy = field("legacy-1");
  return [
    n?.kind === "concealed" && n?.group === "document" && n?.value === "E1234567" ? "号码已加密保存" : "",
    d?.kind === "date" && d?.value === "2031-05-06" ? "日期已保存" : "",
    legacy?.value === "M-42" && legacy?.futureKey === 7 ? "旧字段保留" : "",
    item()?.futureTop === "keep" && item()?.identity?.lastName === "林" ? "未知字段保留" : "",
    `字段数量 ${(item()?.customFields ?? []).length}`,
  ];
}
mount(() => <View style={{ flex: 1 }}>
  <Btn label="准备测试库" onPress={async () => {
    try {
      await unlock("synthetic-preview-password");
      await createItem("identity", { id: "identity-fixture", title: "QA", identity: { lastName: "林" }, futureTop: "keep",
        customFields: [{ id: "legacy-1", group: "misc", label: "会员号", kind: "text", value: "M-42", futureKey: 7 }] } as any);
      ready.set(true);
    } catch (e) { error.set(String(e)); }
  }} />
  <T>{error()}</T>
  <If when={ready()}><>
    <Btn label="保存并重读" onPress={async () => { await flush(); await load(); }} />
    <Btn label="切换编辑" onPress={() => editing.update((v) => !v)} />
    <Each of={checks()}>{(t: () => string) => <T>{t()}</T>}</Each>
    <Scroll style={{ flex: 1 }}>
      <IdentityDocument item={item()!} editing={editing()} />
      <CustomFields item={item()!} editing={editing()} skip={isDocumentField} />
    </Scroll>
  </></If>
  <SheetHost />
</View>);
