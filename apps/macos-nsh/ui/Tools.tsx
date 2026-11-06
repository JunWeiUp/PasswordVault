// Tools: the password generator and password health.
import { effect, Scroll, signal, View } from "nsh";
import { Icon } from "./icons";
import {
  Banner, Btn, copySecret, Empty, Group, openSheet, Row, SheetFooter, SheetTitle, Strength, T, Toggle,
} from "./kit";
import { audit, createItem, edit, generatePassword, items, lock, onLock, refreshAudit, reveal, toast, type Item } from "./store";
import { Tile } from "./ItemList";
import { c, layout, MONO } from "./theme";

type GenOptions = { mode: "random" | "pin"; length: number; upper: boolean; lower: boolean; digits: boolean; symbols: boolean };
const options = signal<GenOptions>({ mode: "random", length: 20, upper: true, lower: true, digits: true, symbols: true });
const output = signal("");
const history = signal<string[]>([]);
onLock(() => {
  history.set([]);
  output.set("");
});

function pin(length: number) {
  return Array.from({ length }, () => String(crypto.randomInt(0, 10))).join("");
}

async function regenerate() {
  const o = options();
  if (o.mode === "pin") return output.set(pin(Math.min(Math.max(o.length, 4), 12)));
  if (!(o.upper || o.lower || o.digits || o.symbols)) return output.set("");
  try {
    output.set(await generatePassword({ length: o.length, upper: o.upper, lower: o.lower, digits: o.digits, symbols: o.symbols }));
  } catch {
    output.set("");
  }
}

function entropy(o: GenOptions) {
  if (o.mode === "pin") return Math.round(Math.min(o.length, 12) * Math.log2(10));
  const n = (o.lower ? 26 : 0) + (o.upper ? 26 : 0) + (o.digits ? 10 : 0) + (o.symbols ? 20 : 0);
  return n ? Math.round(o.length * Math.log2(n)) : 0;
}

function ColoredPassword(props: { value: string; size?: number }) {
  return (
    <T mono size={props.size ?? 22} selectable style={{ flex: 1 }}>
      {[...props.value].map((ch) => (
        <T mono size={props.size ?? 22} color={/[0-9]/.test(ch) ? c().blue : /[A-Za-z]/.test(ch) ? c().ink : c().orange}>{ch}</T>
      ))}
    </T>
  );
}

function ToolHeader(props: { title: string; right?: any }) {
  return (
    <View desktop={{ windowDrag: true }} style={{ height: layout.toolbar, flexDirection: "row", alignItems: "center", paddingLeft: 26, paddingRight: 18, gap: 8, borderBottomWidth: 1, borderBottomColor: c().line }}>
      <Icon name="tools" size={12} tint={c().muted} />
      <T size={12} color={c().muted}>工具</T>
      <Icon name="chev" size={11} tint={c().faint} />
      <T size={12} weight="500" style={{ flex: 1 }}>{props.title}</T>
      <View desktop={{ windowDrag: false }} style={{ flexDirection: "row", gap: 6 }}>
        {props.right}
        <Btn label="锁定" icon="lock" kind="ghost" onPress={() => void lock()} />
      </View>
    </View>
  );
}

export function Generator() {
  effect(() => {
    options();
    void regenerate();
  });
  const o = () => options();
  const set = (patch: Partial<GenOptions>) => options.update((v) => ({ ...v, ...patch }));
  const bits = () => entropy(o());
  const level = () => (bits() >= 80 ? 4 : bits() >= 60 ? 3 : bits() >= 40 ? 2 : 1);
  const none = () => o().mode === "random" && !(o().upper || o().lower || o().digits || o().symbols);
  const copy = () => {
    if (!output()) return;
    history.update((h) => [output(), ...h.filter((x) => x !== output())].slice(0, 5));
    void copySecret(output(), "密码");
  };
  return (
    <View style={{ flex: 1, backgroundColor: c().surface }}>
      <ToolHeader title="密码生成器" />
      <Scroll style={{ flex: 1 }} contentStyle={{ paddingHorizontal: 48, paddingTop: 40, paddingBottom: 40 }}>
        <T size={24} weight="600">密码生成器</T>
        <T color={c().muted} style={{ marginTop: 6, marginBottom: 22 }}>在本机生成，不联网，不自动保存。</T>
        <View style={{ flexDirection: "row", gap: 28, alignItems: "flex-start" }}>
          <View style={{ flex: 1, minWidth: 0 }}>
            <Row gap={12} style={{ borderWidth: 1, borderColor: c().line, borderRadius: 12, paddingHorizontal: 22, paddingVertical: 20 }}>
              <If when={!none()} else={<T color={c().muted} style={{ flex: 1 }}>至少选择一种字符类型。</T>}>
                <ColoredPassword value={output()} />
              </If>
              <View role="button" accessibilityLabel="重新生成" tooltip="重新生成 ⌘R" onPress={() => void regenerate()} style={{ padding: 6, borderRadius: 6, cursor: "pointer" }} hoverStyle={{ backgroundColor: c().field }}>
                <Icon name="sync" size={20} tint={c().muted} />
              </View>
            </Row>
            <Strength level={level()} />
            <T size={11.5} color={c().muted} style={{ marginTop: 8 }}>约 {bits()} 位熵。{level() >= 4 ? "适合主密码以外的所有账号。" : "建议增加长度或字符类型。"}</T>
            <Row gap={8} style={{ marginTop: 16 }}>
              <Btn label="复制" icon="copy" kind="primary" disabled={none() || !output()} onPress={copy} />
              <Btn label="用此密码新建账号" icon="plus" disabled={none() || !output()} onPress={() => void createItem("password", { password: output() }).then(() => toast("已创建账号，密码已填入"))} />
            </Row>
            <Row style={{ marginTop: 26, marginBottom: 8, justifyContent: "space-between" }}>
              <T size={12.5} weight="600">本次复制历史</T>
              <T size={11} color={c().muted}>仅保存在内存，锁定后清空</T>
            </Row>
            <If when={history().length} else={<T size={11.5} color={c().muted}>复制过的密码会暂时出现在这里。</T>}>
              <Group>
                <Each of={history()}>
                  {(h) => (
                    <Row style={{ paddingVertical: 9, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
                      <T mono size={12.5} style={{ flex: 1 }}>{"•".repeat(Math.min(h().length, 20))}</T>
                      <Btn kind="ghost" icon="copy" label="复制" onPress={() => void copySecret(h(), "密码")} />
                    </Row>
                  )}
                </Each>
              </Group>
            </If>
          </View>
          <View style={{ width: 300 }}>
            <View style={{ flexDirection: "row", backgroundColor: c().field, borderRadius: 7, padding: 2, marginBottom: 14 }}>
              {([["random", "随机字符"], ["pin", "PIN"]] as const).map(([m, label]) => (
                <View role="button" accessibilityState={{ selected: o().mode === m }} onPress={() => set({ mode: m, length: m === "pin" ? 6 : 20 })}
                  style={{ flex: 1, alignItems: "center", paddingVertical: 5, borderRadius: 5, backgroundColor: o().mode === m ? c().surface : "transparent", cursor: "pointer" }}>
                  <T size={12} weight={o().mode === m ? "600" : "400"} color={o().mode === m ? c().blue : c().muted}>{label}</T>
                </View>
              ))}
            </View>
            <Group>
              <Row style={{ paddingVertical: 11, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
                <View style={{ flex: 1 }}>
                  <T>长度</T>
                  <T size={11} color={c().muted}>{o().mode === "pin" ? "4–12 位" : "8–64 个字符"}</T>
                </View>
                <Btn kind="ghost" label="−" onPress={() => set({ length: Math.max(o().mode === "pin" ? 4 : 8, o().length - 1) })} />
                <T mono weight="600" style={{ width: 26, textAlign: "center" }}>{o().length}</T>
                <Btn kind="ghost" label="＋" onPress={() => set({ length: Math.min(o().mode === "pin" ? 12 : 64, o().length + 1) })} />
              </Row>
              <If when={o().mode === "random"}>
                <Toggle title="大写字母 A–Z" checked={o().upper} onChange={(v) => set({ upper: v })} />
                <Toggle title="小写字母 a–z" checked={o().lower} onChange={(v) => set({ lower: v })} />
                <Toggle title="数字 0–9" checked={o().digits} onChange={(v) => set({ digits: v })} />
                <Toggle title="符号 !@#$" checked={o().symbols} onChange={(v) => set({ symbols: v })} />
              </If>
            </Group>
            <T size={11} color={c().muted} style={{ marginTop: 8 }}>随机字符由加密核心生成；易记短语将在后续版本提供。</T>
          </View>
        </View>
      </Scroll>
    </View>
  );
}

/** Proposes a new password for `item`; the old one goes to password history. */
export function askGeneratedPassword(item: Item) {
  const value = signal("");
  const make = async () => value.set(await generatePassword({ length: 20, upper: true, lower: true, digits: true, symbols: true }).catch(() => ""));
  void make();
  openSheet({
    render: (close) => (
      <View style={{ gap: 8 }}>
        <SheetTitle title="生成新密码" text="20 个字符 · 大小写字母、数字与符号。旧密码会进入密码历史。" />
        <Row gap={10} style={{ borderWidth: 1, borderColor: c().line, borderRadius: 10, padding: 14, marginVertical: 6 }}>
          <ColoredPassword value={value()} size={17} />
          <View role="button" accessibilityLabel="重新生成" onPress={() => void make()} style={{ padding: 4, cursor: "pointer" }}><Icon name="sync" size={18} tint={c().muted} /></View>
        </Row>
        <SheetFooter>
          <Btn label="取消" onPress={close} />
          <Btn label="使用此密码" kind="primary" disabled={!value()} onPress={() => {
            edit(item.id, (d) => (d.password = value()));
            close();
            toast("已替换密码，记得在网站同步修改");
          }} />
        </SheetFooter>
      </View>
    ),
  });
}

const healthTab = signal<"weak" | "reused" | "expired">("weak");

export function Health() {
  effect(() => void refreshAudit());
  const list = (k: "weak" | "reused" | "expired") => items().filter((i) => !i.isDeleted && audit()[i.id]?.[k]);
  const card = (k: "weak" | "reused" | "expired", title: string, note: string) => {
    const n = () => list(k).length;
    const on = () => healthTab() === k;
    return (
      <View role="button" accessibilityState={{ selected: on() }} onPress={() => healthTab.set(k)}
        style={{ flex: 1, borderWidth: on() ? 2 : 1, borderColor: on() ? c().blue : c().line, borderRadius: 12, padding: 16, gap: 4, cursor: "pointer" }}>
        <T size={11.5} color={c().muted}>{title}</T>
        <T size={26} weight="600" color={n() ? c().orange : c().green}>{n()}</T>
        <T size={11.5} color={c().muted}>{note}</T>
      </View>
    );
  };
  return (
    <View style={{ flex: 1, backgroundColor: c().surface }}>
      <ToolHeader title="密码健康" right={<Btn label="重新检查" icon="sync" onPress={() => void refreshAudit().then(() => toast("检查完成"))} />} />
      <Scroll style={{ flex: 1 }} contentStyle={{ paddingHorizontal: 48, paddingTop: 40, paddingBottom: 40 }}>
        <T size={24} weight="600">密码健康</T>
        <T color={c().muted} style={{ marginTop: 6, marginBottom: 22 }}>检查弱密码、重复使用和超过设定更换周期的密码。这不是对应用本身的安全审计。</T>
        <Row gap={10} style={{ marginBottom: 22, alignItems: "stretch" }}>
          {card("weak", "弱密码", "少于 12 个字符")}
          {card("reused", "重复使用", "多个账号使用同一密码")}
          {card("expired", "需要更换", "超过条目设定的更换周期")}
        </Row>
        <Banner tone="info" title="在线泄露检查尚未接入此预览版">Have I Been Pwned 检查（默认关闭、需你主动开始）仍由 SwiftUI 版提供。</Banner>
        <If when={list(healthTab()).length} else={<Empty icon="check" title="没有发现问题" text="这一类没有需要处理的密码。" />}>
          <Group style={{ paddingHorizontal: 0 }}>
            <Each of={list(healthTab())} key={(i) => i.id}>
              {(item) => (
                <Row gap={12} style={{ paddingHorizontal: 14, paddingVertical: 11, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
                  <Tile item={item()} />
                  <View style={{ flex: 1 }}>
                    <T weight="600">{item().title}</T>
                    <T size={11.5} color={c().muted}>{item().username}</T>
                  </View>
                  <Btn label="打开" onPress={() => reveal(item())} />
                  <Btn label="更换密码" kind="primary" onPress={() => { reveal(item()); askGeneratedPassword(item()); }} />
                </Row>
              )}
            </Each>
          </Group>
        </If>
      </Scroll>
    </View>
  );
}

export { MONO };
