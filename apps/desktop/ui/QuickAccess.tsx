// Quick Access: a keyboard-first search panel over the window. Closes on lock.
import { computed, signal, View } from "nsh";
import { Dialog, Input } from "nsh/base";
import { Icon } from "./icons";
import { copySecret, T } from "./kit";
import { items, onLock, reveal, totpCode, TYPE_NAME, type Item } from "./store";
import { Tile } from "./ItemList";
import { c, MONO, radius, fs } from "./theme";

const open = signal(false);
const text = signal("");
const index = signal(0);
onLock(() => open.set(false));

export function openQuickAccess() {
  text.set("");
  index.set(0);
  open.set(true);
}
export const quickAccessOpen = () => open();

const results = computed<Item[]>(() => {
  const q = text().trim().toLowerCase();
  return items()
    .filter((i) => !i.isDeleted && i.type !== "secureNote")
    .filter((i) => !q || [i.title, i.username, i.url, i.issuer].filter(Boolean).join(" ").toLowerCase().includes(q))
    .slice(0, 8);
});

async function primary(item: Item | undefined) {
  if (!item) return;
  open.set(false);
  if (item.type === "totp" || (item.type === "password" && !item.password && item.secret)) {
    await copySecret(await totpCode(item.secret, item.period ?? 30), "验证码");
  } else if (item.type === "password") await copySecret(item.password, "密码");
  else if (item.type === "creditCard") await copySecret(String(item.card?.number ?? "").replace(/\s/g, ""), "卡号");
  else if (item.type === "crypto") await copySecret(item.address, "地址");
  else reveal(item);
}

function key(e: { key: string }) {
  const n = results().length;
  if (e.key === "ArrowDown") index.set(Math.min(n - 1, index() + 1));
  else if (e.key === "ArrowUp") index.set(Math.max(0, index() - 1));
  else if (e.key === "Escape") open.set(false);
}

export function QuickAccessHost() {
  return (
    <If when={open()}>
      <Dialog open animation="fade" onOpenChange={({ open: visible }) => !visible && open.set(false)} backdropStyle={{ backgroundColor: "rgba(13,23,40,0.2)" }}
        style={{ alignSelf: "center", marginTop: 120, width: 640, backgroundColor: c().surface, borderRadius: radius.sheet, borderWidth: 1, borderColor: c().line, overflow: "hidden" }}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 18, paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: c().line }}>
          <Icon name="search" size={20} tint={c().muted} />
          <Input testID="quick-access" autoFocus value={text()} placeholder="搜索账号、验证码、钱包…" accessibilityLabel="快速访问搜索"
            onChange={({ value }) => { text.set(value); index.set(0); }}
            onKeyPress={key}
            onSubmit={() => void primary(results()[index()])}
            style={{ flex: 1, fontSize: fs(18), backgroundColor: "transparent", borderWidth: 0, color: c().ink }} />
          <T size={11} color={c().faint}>esc</T>
        </View>
        <View style={{ padding: 6, maxHeight: 380 }}>
          <If when={results().length} else={<T color={c().muted} align="center" style={{ padding: 30 }}>没有匹配的项目</T>}>
            <Each of={results()} key={(i) => i.id}>
              {(item, i) => {
                const on = () => index() === i();
                return (
                  <View role="button" accessibilityState={{ selected: on() }} onMouseEnter={() => index.set(i())} onPress={() => void primary(item())}
                    style={{ flexDirection: "row", alignItems: "center", gap: 12, paddingHorizontal: 10, paddingVertical: 8, borderRadius: 8, backgroundColor: on() ? c().blue : "transparent", cursor: "pointer" }}>
                    <Tile item={item()} size={30} />
                    <View style={{ flex: 1 }}>
                      <T weight="600" color={on() ? "#ffffff" : c().ink}>{item().title}</T>
                      <T size={11.5} color={on() ? "#dbe5ff" : c().muted}>{TYPE_NAME[item().type]} · {item().username || item().issuer || item().network || ""}</T>
                    </View>
                    <T size={11} color={on() ? "#dbe5ff" : c().faint} style={{ fontFamily: MONO }}>↩</T>
                  </View>
                );
              }}
            </Each>
          </If>
        </View>
        <View style={{ flexDirection: "row", gap: 14, paddingHorizontal: 16, paddingVertical: 9, borderTopWidth: 1, borderTopColor: c().line }}>
          <T size={11} color={c().muted}>↩ 复制密码/验证码</T>
          <T size={11} color={c().muted}>↑↓ 选择</T>
          <T size={11} color={c().muted}>esc 关闭</T>
          <View style={{ flex: 1 }} />
          <T size={11} color={c().muted}>锁定时自动关闭</T>
        </View>
      </Dialog>
    </If>
  );
}
