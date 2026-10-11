import { useEffect, useState } from "preact/hooks";

export function BackgroundSyncPanel({ ready, readReady, readsLocked, autoUnlockReady, busy, onConfigure, onDisable, onDisableAuto }: {
  ready: boolean; readReady?: boolean; readsLocked?: boolean; autoUnlockReady?: boolean; busy: boolean;
  onConfigure: (password: string, autoUnlock: boolean) => Promise<unknown>;
  onDisable: () => Promise<unknown>;
  onDisableAuto: () => Promise<unknown>;
}) {
  const [password, setPassword] = useState("");
  const [editing, setEditing] = useState(false);
  const [autoUnlock, setAutoUnlock] = useState(true);
  useEffect(() => {
    if (readReady && !readsLocked) setEditing(false);
  }, [readReady, readsLocked, autoUnlockReady]);
  const form = !ready || editing || readsLocked;
  const panel = <section class="connection-panel" aria-busy={busy}>
    <h2>{readReady ? "Mac 账号已连接" : ready ? "后台保存已开启" : "连接 Mac 资料库"}</h2>
    <p>{readReady
      ? "当前网站的账号可直接查看和填充，Mac 应用无需保持打开。"
      : ready && !readsLocked
        ? "当前是仅保存授权。重新验证主密码后，可显示网站账号并选择自动解锁 Mac。"
        : "输入 Mac 资料库主密码，授权插件读取当前网站账号、填充和保存。"}</p>
    {form ? <form onSubmit={(event) => {
        event.preventDefault();
        const value = password; setPassword("");
        void onConfigure(value, autoUnlock);
      }}>
      <label htmlFor="background-sync-password">Mac 资料库主密码</label>
      <input id="background-sync-password" type="password" autoComplete="off" required
        value={password} onInput={(event) => setPassword(event.currentTarget.value)} disabled={busy} />
      <label class="authorization-option">
        <input type="checkbox" checked={autoUnlock} disabled={busy}
          onChange={(event) => setAutoUnlock(event.currentTarget.checked)} />
        打开 Mac 时自动解锁
      </label>
      <button class="primary wide" disabled={busy}>{busy ? "正在验证…" : "确认授权"}</button>
    </form> : <>
      {(!readReady || !autoUnlockReady) &&
        <button disabled={busy} onClick={() => setEditing(true)}>
          {readReady ? "开启 Mac 自动解锁" : "启用账号显示与自动解锁"}
        </button>}
      {autoUnlockReady && <>
        <p class="muted">Mac 启动自动解锁已开启</p>
        <button class="text-button" disabled={busy} onClick={() => void onDisableAuto()}>关闭 Mac 自动解锁</button>
      </>}
      <button class="text-button" disabled={busy} onClick={() => void onDisable()}>撤销此插件授权</button>
    </>}
    <details><summary>授权与内存占用</summary>
      <p>主密码不会保存，授权由本机登录钥匙串保护。Mac 启动自动解锁仅在启动时尝试一次；本次运行中手动锁定或锁屏后，不会因插件轮询再次解锁。重新启动应用仍会按此选项尝试自动解锁。</p>
      <p>撤销授权或修改主密码后需重新验证。原生组件按需启动、完成即退出。</p>
    </details>
  </section>;
  return readReady && !editing && !readsLocked
    ? <details class="authorization-settings"><summary>Mac 账号已连接 · 管理授权</summary>{panel}</details>
    : panel;
}
