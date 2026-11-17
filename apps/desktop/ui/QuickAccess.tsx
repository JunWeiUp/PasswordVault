// Quick Access: a keyboard-first search panel over the window. Closes on lock.
import { computed, keymap, openUrl, signal, View } from "nsh";
import { Dialog, Input } from "nsh/base";
import { Icon } from "./icons";
import { copySecret, T } from "./kit";
import { items, onLock, reveal, toast, totpCode, TYPE_NAME, type Item } from "./store";
import { websites } from "./entries/model";
import { Tile } from "./ItemList";
import { deviceSubtitle, deviceTitle } from "./devices";
import { searchItems } from "./search";
import { c, MONO, radius, fs } from "./theme";

const open = signal(false);
const text = signal("");
const index = signal(0);
onLock(() => { open.set(false); text.set(""); index.set(0); });

export function openQuickAccess() {
  text.set("");
  index.set(0);
  open.set(true);
}
export const quickAccessOpen = () => open();

const results = computed<Item[]>(() => searchItems(
  items().filter((i) => !i.isDeleted), text(),
).slice(0, 8));

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

/** ⌘C copies the username, ⌘O opens the first website, ⌘↩ shows the item in the main window. */
async function secondary(action: "username" | "website" | "reveal") {
  const item = results()[index()];
  if (!item) return;
  if (action === "username") {
    if (!item.username) return toast("这个项目没有用户名");
    open.set(false);
    await copySecret(item.username, "用户名");
  } else if (action === "website") {
    const site = websites(String(item.url ?? ""))[0];
    if (!site) return toast("这个项目没有网站");
    open.set(false);
    await openUrl(site).catch(() => toast("无法打开该网址"));
  } else {
    open.set(false);
    reveal(item);
  }
}

function QuickKeys() {
  // Bound while the panel is open; removed with it. "always" lets them work in the search field.
  keymap.bind({
    "mod+c": () => void secondary("username"),
    "mod+o": () => void secondary("website"),
    "mod+enter": () => void secondary("reveal"),
  }, { when: "always" });
  return null;
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
      <>
      <QuickKeys />
      <Dialog open animation="fade" onOpenChange={({ open: visible }) => !visible && open.set(false)} backdropStyle={{ backgroundColor: "rgba(13,23,40,0.2)" }}
        style={{ alignSelf: "center", marginTop: 120, width: 640, backgroundColor: c().surface, borderRadius: radius.sheet, borderWidth: 1, borderColor: c().line, overflow: "hidden" }}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 18, paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: c().line }}>
          <Icon name="search" size={20} tint={c().muted} />
          <Input testID="quick-access" autoFocus value={text()} placeholder="搜索全部项目，多个关键词用空格分隔" accessibilityLabel="快速访问搜索"
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
                      <T weight="600" color={on() ? "#ffffff" : c().ink}>{item().type === "device" ? deviceTitle(item()) : item().title || "未命名"}</T>
                      <T size={11.5} color={on() ? "#dbe5ff" : c().muted}>{TYPE_NAME[item().type]} · {item().type === "device" ? deviceSubtitle(item()) : item().username || item().issuer || item().network || ""}</T>
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
          <T size={11} color={c().muted}>{keymap.label("mod+c")} 复制用户名</T>
          <T size={11} color={c().muted}>{keymap.label("mod+o")} 打开网站</T>
          <T size={11} color={c().muted}>{keymap.label("mod+enter")} 在主窗口显示</T>
          <View style={{ flex: 1 }} />
          <T size={11} color={c().muted}>锁定时自动关闭</T>
        </View>
      </Dialog>
      </>
    </If>
  );
}
