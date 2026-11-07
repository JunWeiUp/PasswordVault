import { desktopCapabilities } from "../native";
import { cleanup, signal, View } from "nsh";
import { Scripts } from "passwordvault/native";
import { Banner, Btn, openSheet, SheetFooter, SheetTitle, T } from "../kit";
import { errorText, flush, onLock, phase, toast, vaultInstance } from "../store";
import { type DeviceCommand } from "./model";
export const runnableScript = (title: string) => desktopCapabilities.terminal && /\.(sh|bash|zsh|command|py|js)$/i.test(title);
type TerminalState = { selected: string; options: { id: string; name: string; available: boolean }[] };
const terminals = signal<TerminalState>({ selected: "system", options: [{ id: "system", name: "系统终端", available: true }] });
const terminalName = () => terminals().options.find(t => t.id === terminals().selected)?.name ?? "选择终端";
export async function openScriptRun(row: DeviceCommand) {
  if (!runnableScript(row.title) || phase() !== "unlocked") return;
  const snapshot = { ...row };
  try {
    if (!(await flush()) || phase() !== "unlocked") return;
    const name = await Scripts.run(vaultInstance, snapshot.title, snapshot.text);
    if (phase() === "unlocked") toast(`已交给${name}运行`);
  } catch (e) { if (phase() === "unlocked") toast(errorText(e)); }
}
export function TerminalPreference() {
  if (!desktopCapabilities.terminal) return <T size={12}>Windows 终端运行尚未开放</T>;
  void Scripts.terminals(vaultInstance).then(value => terminals.set(JSON.parse(value))).catch(() => {});
  return <Btn label={`${terminalName()} ▾`} tooltip="选择运行终端，自动记住首选项" onPress={() => openSheet({ width: 450, render: close => <TerminalChooser close={close} /> })} />;
}
function TerminalChooser(props: { close: () => void }) {
  const busy = signal(false), error = signal(""); let alive = true;
  cleanup(() => { alive = false; }); cleanup(onLock(props.close));
  const choose = async (id?: string) => {
    if (busy()) return; busy.set(true); error.set("");
    try {
      const result = id ? await Scripts.selectTerminal(vaultInstance, id) : await Scripts.chooseTerminal(vaultInstance);
      if (!alive) return;
      terminals.set(JSON.parse(result)); props.close();
    } catch (e) { if (alive) error.set(errorText(e)); }
    finally { if (alive) busy.set(false); }
  };
  return <View style={{ gap: 12 }}><SheetTitle title="首选终端" text="选择一次，之后点击运行都会使用它。" />
    {terminals().options.map(t => <Btn label={`${t.name}${t.id === terminals().selected ? " · 当前首选" : ""}${!t.available ? " · 未安装" : ""}`} kind={t.id === terminals().selected ? "primary" : "default"} disabled={busy() || !t.available} onPress={() => void choose(t.id)} />)}
    <Btn label="选择终端应用…" disabled={busy()} onPress={() => void choose()} />
    <T size={12}>支持 Terminal、iTerm2、Ghostty 和 tty7。运行后在终端查看输出、输入或停止任务；锁定密码库不会中断终端任务。</T>
    <If when={error()}><Banner tone="err" title={error()} /></If><SheetFooter><Btn label="关闭" disabled={busy()} onPress={props.close} /></SheetFooter>
  </View>;
}
