// Synthetic in-memory UI fixture: never opens or writes a vault.
import { batch, mount, View } from "nsh";
import { ItemList } from "../ui/ItemList";
import { QuickAccessHost, openQuickAccess } from "../ui/QuickAccess";
import { Btn, T } from "../ui/kit";
import { dest, go, items, query, selected } from "../ui/store";
import { quickCloseAfterCopy } from "../ui/preferences";

batch(() => {
  dest.set("accounts");
  items.set([
    { id: "primary", type: "password", title: "主账号", email: "billing@example.test", accounts: [{ label: "备用", username: "backup-user" }], isFavorite: true },
    { id: "other", type: "password", title: "其他账号", username: "other", password: "fixture-pass" },
    { id: "deleted", type: "password", title: "回收账号", email: "billing@example.test", isDeleted: true },
    { id: "note", type: "secureNote", title: "项目笔记", note: "发布计划", __noteSearchText: "receipt.png" },
    { id: "card", type: "creditCard", title: "付款卡", card: { cardholder: "Fixture Holder" } },
  ]);
});

mount(() => <View style={{ flex: 1 }}>
  <View style={{ flexDirection: "row" }}>
    <Btn testID="show-all" label="所有类型" onPress={() => go("all")} />
    <Btn testID="show-trash" label="查看回收站" onPress={() => go("trash")} />
    <Btn testID="open-quick" label="打开快速访问" onPress={openQuickAccess} />
    <Btn testID="toggle-quick-close" label="切换复制后关闭" onPress={() => quickCloseAfterCopy.set(!quickCloseAfterCopy())} />
  </View>
  <T>{`当前选中 ${selected()?.id ?? "无"}`}</T>
  <T>{`当前查询 ${query()}`}</T>
  <ItemList />
  <QuickAccessHost />
</View>);
