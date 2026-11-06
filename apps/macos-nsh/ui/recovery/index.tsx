import { cleanup, signal, View, Clipboard } from "nsh";
import { Files, RecoveryIO } from "passwordvault/native";
import { Banner, Btn, Group, OptionRow, openSheet, SheetTitle, SheetFooter, TextBox, T, Toggle, confirm } from "../kit";
import { call, errorText, flush, load, onLock, phase, toast, vaultInstance } from "../store";

const warning = "密钥和完整应急备份必须分开保存。密钥不能找回没有备份的数据。更换或停用不会撤销旧备份。";
export const historyWarning = "启用后保存完整条目及附件，并升级数据格式，无法降级。旧客户端将无法打开，请先升级全部设备。启用前自动创建加密快照。";
export function askEnableHistory(done: () => void = () => {}) {
  confirm({ title: "启用完整版本历史？", text: historyWarning, ok: "启用完整历史", onConfirm: () => {
    void (async () => { try { await flush(); await call({ op: "history-enable" }); await load(); done(); toast("完整版本历史已启用"); } catch (e) { toast(errorText(e)); } })();
  } });
}

export function RecoverySettings() {
  const enabled = signal(false), history = signal(false), error = signal("");
  let alive = true;
  cleanup(() => { alive = false; });
  const refresh = async () => { try {
    const r = await call({ op: "recovery-status" }); const h = await call({ op: "history-status" });
    if (alive) { enabled.set(r.enabled); history.set(h.enabled); }
  } catch (e) { if (alive) error.set(errorText(e)); } };
  void refresh();
  return <View><T weight="600">应急恢复</T><Group>
    <OptionRow title={enabled() ? "恢复密钥已启用" : "恢复密钥尚未启用"} note={warning}>
      <Btn label="管理恢复密钥…" onPress={() => openSheet({ width: 610, render: close => <RecoverySetup close={close} done={refresh} /> })} />
    </OptionRow>
  </Group><T weight="600">版本历史</T><Group><OptionRow title={history() ? "完整历史已启用" : "完整版本历史"} note={historyWarning}>
    <Btn label={history() ? "已启用" : "启用…"} disabled={history()} onPress={() => askEnableHistory(refresh)} />
  </OptionRow></Group><T>{error()}</T></View>;
}

function RecoverySetup(props: { close: () => void; done: () => void }) {
  const key = signal(""), password = signal(""), check = signal(""), saved = signal(false);
  const generated = signal(false), enabled = signal(false), busy = signal(false), error = signal("");
  let alive = true, copied = false;
  const clear = () => {
    // Never retain a key in a timer closure. Clear only our own clipboard value.
    if (copied) { const current = key(); void Clipboard.readText().then(v => { if (v === current) void Clipboard.writeText(""); }); }
    key.set(""); password.set(""); check.set("");
  };
  cleanup(() => { alive = false; clear(); });
  cleanup(onLock(() => { clear(); props.close(); }));
  const run = async (fn: () => Promise<void>) => { if (busy()) return; busy.set(true); error.set(""); try { await fn(); } catch (e) { if (alive) error.set(errorText(e)); } finally { if (alive) busy.set(false); } };
  void run(async () => { const r = await call({ op: "recovery-status" }); if (alive) enabled.set(r.enabled); });
  const generate = () => run(async () => { const r = await call({ op: "recovery-generate" }); if (!alive) return; clear(); key.set(r.key); generated.set(true); saved.set(false); });
  const enable = () => run(async () => { if (!ready()) return; await call({ op: "recovery-enable", key: key(), currentPassword: password() }); clear(); if (!alive) return; props.done(); props.close(); toast("恢复密钥已启用，请立即导出应急备份"); });
  const ready = () => generated() && !!password() && saved() && !!check() && check().trim().toLowerCase() === key().split("-")[2]?.toLowerCase();
  return <View style={{ gap: 12 }}><SheetTitle title="离线应急恢复" text={warning} />
    <If when={generated()} else={<><T>{enabled() ? "已启用" : "尚未启用"}</T><Btn label={enabled() ? "更换密钥…" : "生成密钥…"} disabled={busy()} onPress={generate} />
      <If when={enabled()}><TextBox masked value={key()} onChange={v => key.set(v)} label="恢复密钥" placeholder="导出时输入单独保存的恢复密钥" /></If></>}>
      <Banner tone="warn" title="密钥只显示这一次">请保存在这个密码库之外。</Banner>
      <T mono selectable>{key()}</T><Btn label="复制恢复密钥" disabled={busy()} onPress={() => { copied = true; void Clipboard.writeText(key()); }} />
      <Btn label="打印恢复密钥…" disabled={busy()} onPress={() => run(async () => { await RecoveryIO.printKey(key()); })} />
      <TextBox value={check()} onChange={v => check.set(v)} label="第 3 组字符" placeholder="为确认已保存，请输入第 3 组字符" />
      <Toggle title="我已把密钥保存在这个密码库之外" checked={saved()} onChange={v => saved.set(v)} />
    </If>
    <TextBox masked value={password()} onChange={v => password.set(v)} label="当前主密码" placeholder="当前主密码（启用或停用）" />
    <If when={error()}><Banner tone="err" title={error()} /></If>
    <SheetFooter><Btn label="关闭" disabled={busy()} onPress={props.close} />
      <If when={generated()} else={<If when={enabled()}>
        <Btn label="停用密钥…" disabled={busy() || !password()} onPress={() => run(async () => { await call({ op: "recovery-disable", currentPassword: password() }); clear(); if (alive) { enabled.set(false); props.done(); toast("本机恢复已停用，旧备份仍然有效"); } })} />
        <Btn label="导出应急备份…" disabled={busy() || !key()} onPress={() => run(async () => {
          await flush(); const path = await Files.pickSave("导出应急备份", "PasswordVault-emergency.pvbackup", ["pvbackup"]);
          if (!path || !alive || phase() !== "unlocked") return;
          await RecoveryIO.export(vaultInstance, key(), path); clear(); if (alive) toast("应急备份已保存，请与密钥分开存放");
        })} />
      </If>}><Btn label="确认并启用" kind="primary" disabled={busy() || !ready()} onPress={enable} /></If>
    </SheetFooter></View>;
}

export const askRecoveryReset = () => openSheet({ render: close => <RecoveryUnlock close={close} archive={false} /> });
export const askEmergencyRestore = () => openSheet({ render: close => <RecoveryUnlock close={close} archive /> });
function RecoveryUnlock(props: { close: () => void; archive: boolean }) {
  const key = signal(""), password = signal(""), again = signal(""), path = signal(""), error = signal(""), busy = signal(false), approved = signal(false);
  let alive = true;
  cleanup(() => { alive = false; key.set(""); password.set(""); again.set(""); });
  const ready = () => !!key() && password().length >= 10 && password() === again() && (!props.archive || !!path());
  const submit = async () => {
    if (!ready() || busy()) return;
    if (!approved()) { approved.set(true); return; }
    busy.set(true); error.set("");
    try {
      const status = await call({ op: "status" });
      if (props.archive ? status.exists : !status.exists || status.unlocked) throw new Error(props.archive ? "AlreadyExists" : "InvalidData");
      if (props.archive) await RecoveryIO.restore(vaultInstance, key(), password(), path());
      else await call({ op: "recovery-reset-password", key: key(), newPassword: password() });
      key.set(""); password.set(""); again.set("");
      await load(); if (alive) props.close(); toast("恢复完成，请重新检查设备授权与恢复设置");
    } catch (e) { if (alive) { error.set(errorText(e)); approved.set(false); } } finally { if (alive) busy.set(false); }
  };
  return <View style={{ gap: 12 }}><SheetTitle title={props.archive ? "使用应急备份与恢复密钥" : "使用恢复密钥重设主密码"} text={props.archive ? "将备份恢复为新密码库，不会覆盖已有密码库。" : "使用事先启用的恢复密钥重设本机主密码。"} />
    <If when={props.archive}><Btn label={path() ? "已选择应急备份 · 重新选择…" : "选择应急备份…"} disabled={busy()} onPress={async () => { try { const p = await Files.pickOpen("选择应急备份", ["pvbackup"]); if (p && alive) path.set(p); } catch (e) { if (alive) error.set(errorText(e)); } }} /></If>
    <TextBox masked value={key()} onChange={v => { key.set(v); approved.set(false); }} label="恢复密钥" placeholder="恢复密钥" />
    <TextBox masked value={password()} onChange={v => { password.set(v); approved.set(false); }} label="新主密码" placeholder="新主密码（至少 10 个字符）" />
    <TextBox masked value={again()} onChange={v => { again.set(v); approved.set(false); }} label="确认新主密码" placeholder="再次输入新主密码" />
    <If when={approved()}><Banner tone="warn" title="确认恢复？">恢复后将使用新主密码解锁。旧备份与已有设备上的副本不受影响。</Banner></If>
    <If when={error()}><Banner tone="err" title={error()} /></If>
    <SheetFooter><Btn label="取消" disabled={busy()} onPress={props.close} /><Btn label={busy() ? "正在恢复…" : approved() ? "确认恢复" : "恢复"} kind="primary" disabled={!ready() || busy()} onPress={submit} /></SheetFooter>
  </View>;
}
