import { desktopCapabilities } from "../native";
// Browser controls reuse the settings kit; capabilities remain native-only.
import { signal, View } from "nsh";
import { Browser } from "passwordvault/native";
import { Banner, Btn, Group, OptionRow, T, Toggle, confirm } from "../kit";
import { call, errorText, load, settings, toast, vaultInstance } from "../store";
import { c } from "../theme";

let pendingId = "";
/** Install once at app startup after the Vault session exists; return cleanup. */
export function connectBrowser(): () => void {
  if (!desktopCapabilities.browser) return () => {};
  try { Browser.start(vaultInstance); } catch { /* Unsigned development is intentionally unavailable. */ }
  const timer = setInterval(() => {
    const pending = Browser.pending();
    const request = pending ? JSON.parse(pending) as { extensionId: string; challenge: string } : null;
    const id = request?.challenge ?? "";
    if (!id) { pendingId = ""; return; }
    if (id === pendingId) return;
    pendingId = id;
    confirm({ title: "连接浏览器扩展？", text: `${request?.extensionId}\n允许此扩展在资料库解锁时读取当前网站账号、填充与保存。请求将在 35 秒后失效。`, ok: "允许连接", onConfirm: () => { Browser.approve(id, true); void load(); } });
  }, 500);
  return () => { clearInterval(timer); Browser.cancelStartup(); };
}
export function BrowserPage() {
  if (!desktopCapabilities.browser) return <Banner tone="info" title="Windows 浏览器连接尚未开放">你可以在应用中查看、复制和管理账号。</Banner>;
  const rows = signal<{ browser: string; registered: boolean; otherApp: boolean }[]>([]);
  const error = signal("");
  const busy = signal(false);
  const startup = signal(Browser.startupEnabled(vaultInstance));
  const refresh = () => { try { rows.set(JSON.parse(Browser.registrations())); error.set(""); } catch (e) { error.set(String(e)); } };
  refresh();
  const act = async (fn: () => any) => { if (busy()) return; busy.set(true); try { await fn(); refresh(); } catch (e) { error.set(errorText(e)); } finally { busy.set(false); } };
  const revoke = (id: string) => confirm({ title: id ? "撤销此扩展？" : "撤销全部浏览器连接？", text: "配对需要重新确认；所有后台保存、读取与启动解锁授权也将失效，已保存的账号保留。", ok: "撤销", danger: true, onConfirm: () => void act(async () => { await Browser.revoke(vaultInstance, id); await load(); toast("浏览器授权已撤销"); }) });
  const pairs = () => Object.entries(settings().browserPairings ?? {}).map(([id, value]) => ({ id, count: typeof value === "string" ? Number(!!value) : Array.isArray(value) ? value.length : 0 })).filter((p) => p.count > 0);
  return <View style={{ gap: 14 }}>
    <T size={19} weight="600">浏览器</T>
    <T color={c().muted}>通过本机连接读取、填充和保存当前网站的账号。</T>
    <If when={error()}><Banner tone="warn" title="连接操作未完成">{error()} · 请使用已签名的预览安装包。</Banner></If>
    <Group>
      <Each of={rows()}>{(row) => <OptionRow title={row().browser} note={row().registered ? "已连接此预览版" : row().otherApp ? "已登记其他 Mac 版本；登记将切换到此预览版" : "未登记"}>
        <Btn label={row().registered ? "取消登记" : "登记连接"} disabled={busy()} onPress={() => {
          const go = () => void act(() => Browser.register(row().browser, !row().registered));
          if (row().otherApp) confirm({ title: "切换浏览器连接？", text: "此浏览器后续请求将发给当前预览版。可在原版本设置中重新登记。", ok: "切换连接", onConfirm: go }); else go();
        }} />
      </OptionRow>}</Each>
    </Group>
    <T weight="600">已授权的插件</T>
    <Group><Each of={pairs()}>{(pair) => <OptionRow title={pair().id} note={`${pair().count} 个浏览器配置文件连接`}><Btn label="撤销" disabled={busy()} onPress={() => revoke(pair().id)} /></OptionRow>}</Each>
      <If when={!pairs().length}><T color={c().muted}>尚无已配对插件。在扩展中选择「连接 Mac」后在这里确认。</T></If>
      <Btn label="撤销全部连接" disabled={busy() || !pairs().length} onPress={() => revoke("")} />
    </Group>
    <Group>
      <OptionRow title="后台保存与读取" note="在插件中输入主密码授权；旧授权仍然仅允许追加保存。撤销会使所有后台范围失效。"><Btn label="撤销全部后台授权" disabled={busy()} onPress={() => confirm({ title: "撤销后台授权？", text: "后台保存、读取与启动自动解锁将全部停用。", ok: "撤销", danger: true, onConfirm: () => void act(() => call({ op: "revoke-background" })) })} /></OptionRow>
      <Toggle title="允许已授权插件在 Mac 冷启动时解锁" note="还需在插件中开启启动解锁。手动锁定后，轮询不会重新解锁。" checked={startup()} onChange={(v) => void act(() => { Browser.setStartupEnabled(vaultInstance, v); startup.set(v); })} />
    </Group>
    <Banner tone="info" title="待同步的离线保存">待同步记录加密保存在浏览器扩展内。打开插件会重试合并；成功后记录才从队列移除。Mac 无法直接读取队列数量。</Banner>
    <Btn label="刷新已合并的账号" onPress={() => void act(load)} disabled={busy()} />
  </View>;
}
