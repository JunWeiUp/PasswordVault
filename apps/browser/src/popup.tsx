import { t, fmt, useLocale } from "./i18n";
import {StructuredFill} from "./StructuredFill";
import {PasskeyApproval} from "./PasskeyApproval";
import { render } from "preact";
import { useEffect, useState, useRef } from "preact/hooks";
import { authenticate, errorText, message, status, lock } from "./client";
import { AccountSecret } from "./AccountSecret";
import { BackgroundSyncPanel } from "./BackgroundSyncPanel";
import { NativeConnectionPanel } from "./NativeConnectionPanel";
import { MAC_DOWNLOAD_URL } from "./native-connection";
import "./style.css";
import { version } from "../package.json";
import { tileFor } from "./tiles";
import { syncTone } from "./popup-state";
function Popup() {
  useLocale();
  const tabParameter = new URL(location.href).searchParams.get("sourceTabId");
  const sourceTabId =
    tabParameter && /^\d+$/.test(tabParameter)
      ? Number(tabParameter)
      : undefined;
  const [state, setState] = useState<any>();
  const [error, setError] = useState("");
  const [macOpenFailed, setMacOpenFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [matches, setMatches] = useState<any>();
  const [captured, setCaptured] = useState<any>();
  const [matchesError, setMatchesError] = useState("");
  const [notice, setNoticeText] = useState("");
  const [noticeTone, setNoticeTone] = useState<"ok" | "muted">("ok");
  const [syncing, setSyncing] = useState(false);
  const setNotice = (text: string, tone: "ok" | "muted" = "ok") => { setNoticeText(text); setNoticeTone(tone); };
  const busyRef = useRef(false);
  const refreshing = useRef(0);
  const revision = useRef(0);
  async function refresh() {
    const generation = ++revision.current;
    refreshing.current++;
    try {
      const s = await status();
      if (generation !== revision.current) return;
      setState(s);
      setMatchesError("");
      if (s.mode === "native" || s.unlocked) {
        try {
          const found = await message({
            action: "matches",
            tabId: sourceTabId,
          });
          if (generation !== revision.current) return;
          setMatches(found);
          setCaptured((old: any) => {
            if (
              old &&
              (old.origin !== found.origin ||
                old.tabId !== found.id ||
                (old.mode && old.mode !== s.mode))
            )
              return found.pending;
            if (old?.expires && old.id !== found.pending?.id)
              return found.pending;
            return old ?? found.pending;
          });
        } catch (e) {
          if (generation !== revision.current) return;
          setMatches(undefined);
          setCaptured(undefined);
          if (e instanceof Error && e.message === "unpaired")
            setState({ ...s, paired: false });
          else setMatchesError(t(errorText(e)));
        }
      } else {
        setMatches(undefined);
        setCaptured(undefined);
      }
    } finally {
      refreshing.current--;
    }
  }
  async function run(work: () => Promise<unknown>) {
    if (busyRef.current) return;
    busyRef.current = true;
    revision.current++;
    setError("");
    setNotice("");
    setBusy(true);
    try {
      await work();
      await refresh();
    } catch (e) {
      setError(t(errorText(e)));
      await refresh().catch(() => {});
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }
  useEffect(() => {
    void run(async () => {});
    const timer = setInterval(() => {
      if (!busyRef.current && !refreshing.current)
        void refresh().catch((e) => setError(t(errorText(e))));
    }, 2000);
    return () => {
      revision.current++;
      clearInterval(timer);
    };
  }, []);
  useEffect(() => {
    if (captured) {
      setNotice("");
      setError("");
    }
  }, [captured?.id, captured?.origin, captured?.tabId]);
  const openMac = () => run(async () => {
    setMacOpenFailed(false);
    try {
      await message({ action: "open-native" });
    } catch (e) {
      if (e instanceof Error && ["native-host-missing", "native-unavailable"].includes(e.message)) {
        setMacOpenFailed(true);
        return;
      }
      throw e;
    }
  });
  const strengthOf = (pw: string) => {
    if (!pw) return 0;
    const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^a-zA-Z0-9]/].filter((r) => r.test(pw)).length;
    if (pw.length < 10) return 1;
    if (pw.length < 12 || classes < 2) return 2;
    if (pw.length < 16 || classes < 3) return 3;
    return 4;
  };
  const strengthLevel = strengthOf(password);
  const nativeDisconnected =
    state?.mode === "native" &&
    state.available === false &&
    !state.readReady &&
    !state.syncReady;
  const creatingIndependent =
    state && state.mode !== "native" && !state.unlocked && !state.exists;
  const manage = () =>
    chrome.tabs.create({ url: chrome.runtime.getURL("index.html") });
  return (
    <main class={`popup${captured ? " has-capture" : ""}`}>
      <header class="brand">
        <span class="brand-icon">
          <img src="./brand.png" alt="" width="30" height="30" />
        </span>
        <strong>PasswordVault</strong>
        <span class="brand-version" aria-label={fmt(t("插件版本 {version}"),{"version":version})}>v{version}</span>
        <button class="icon-button mac-launch" title={t("打开 Mac 应用")} aria-label={t("打开 Mac 应用")} disabled={busy} onClick={openMac}>
          <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <rect x="3" y="3" width="18" height="13" rx="2" />
            <path d="M9 21h6M12 16v5M8 12l8-6M11 6h5v5" />
          </svg>
        </button>
      </header>
      {macOpenFailed && (
        <aside class="mac-download-notice" role="status">
          <p>{t("未能打开 Mac 应用。尚未安装？请前往 GitHub 下载；已安装请在「设置 → 浏览器」重新登记连接。")}</p>
          <a href={MAC_DOWNLOAD_URL} target="_blank" rel="noopener noreferrer">{t("前往 GitHub 下载 ↗")}</a>
          <button class="text-button" onClick={() => setMacOpenFailed(false)} aria-label={t("关闭下载提示")}>{t("关闭")}</button>
        </aside>
      )}
      {sourceTabId !== undefined && (
        <button
          class="text-button"
          onClick={async () => {
            await chrome.tabs.update(sourceTabId, { active: true });
            window.close();
          }}
        >
          {t("返回登录页面")}
        </button>
      )}
      <div class="mode-switch" aria-label={t("资料库模式")}>
        <button
          disabled={busy}
          aria-pressed={state?.mode === "native"}
          onClick={() => run(() => message({ action: "mode", mode: "native" }))}
        >
          {t("连接 Mac")}
        </button>
        <button
          disabled={busy}
          aria-pressed={state?.mode === "independent"}
          onClick={() =>
            run(() => message({ action: "mode", mode: "independent" }))
          }
        >
          {t("独立资料库")}
        </button>
      </div>
      {error && !captured && (
        <p class="error" role="alert">
          {error}
        </p>
      )}
      {!state ? (
        <section class="popup-empty">
          <p class="muted">{error ? t("暂时无法读取连接状态") : t("正在连接…")}</p>
          {error && !captured && (
            <button disabled={busy} onClick={() => run(async () => {})}>
              {t("重新检测")}
            </button>
          )}
        </section>
      ) : state.mode !== "native" && !state.unlocked ? (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (!state.exists && password !== confirmPassword) {
              setError(t("两次输入的主密码不一致。"));
              return;
            }
            const value = password;
            setPassword("");
            setConfirmPassword("");
            setShowPassword(false);
            setShowConfirm(false);
            void run(() => authenticate(value, !state.exists));
          }}
        >
          <section class="popup-empty">
            <span class="lock-symbol" aria-hidden="true">
              <svg width="42" height="42" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
                <rect x="4" y="11" width="16" height="10" rx="2" />
                <path d="M8 11V7a4 4 0 0 1 8 0v4" />
              </svg>
            </span>
            <h2>{state.exists ? t("解锁资料库") : t("创建独立资料库")}</h2>
            <p>
              {state.exists
                ? t("使用主密码继续。")
                : t("数据加密保存在此浏览器。请记住主密码。")}
            </p>
            <div class="capture-secret">
              <input
                autoFocus
                type={showPassword ? "text" : "password"}
                autoComplete={state.exists ? "current-password" : "new-password"}
                minLength={state.exists ? 1 : 10}
                required
                placeholder={
                  state.exists ? t("主密码") : t("设置主密码（至少 10 字符）")
                }
                value={password}
                onInput={(e) => setPassword(e.currentTarget.value)}
              />
              <button
                type="button"
                class="secret-toggle"
                aria-label={showPassword ? t("隐藏密码") : t("显示密码")}
                title={showPassword ? t("隐藏密码") : t("显示密码")}
                aria-pressed={showPassword}
                onClick={() => setShowPassword((v) => !v)}
              >
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                  <path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z" />
                  <circle cx="12" cy="12" r="3" />
                  {showPassword && <path d="m3 3 18 18" />}
                </svg>
              </button>
            </div>
            {!state.exists && password && (
              <div class={`strength-meter ${strengthLevel <= 1 ? "low" : strengthLevel === 2 ? "mid" : "high"}`} aria-live="polite">
                {[1, 2, 3, 4].map((i) => <i class={i <= strengthLevel ? "on" : ""} />)}
                <span>{[ "", t("弱"), t("一般"), t("良好"), t("强") ][strengthLevel]}</span>
              </div>
            )}
            {!state.exists && (
              <div class="capture-secret">
                <input
                  type={showConfirm ? "text" : "password"}
                  autoComplete="new-password"
                  minLength={10}
                  required
                  placeholder={t("再次输入主密码")}
                  value={confirmPassword}
                  onInput={(e) => setConfirmPassword(e.currentTarget.value)}
                />
                <button
                  type="button"
                  class="secret-toggle"
                  aria-label={showConfirm ? t("隐藏密码") : t("显示密码")}
                  title={showConfirm ? t("隐藏密码") : t("显示密码")}
                  aria-pressed={showConfirm}
                  onClick={() => setShowConfirm((v) => !v)}
                >
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                    <path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z" />
                    <circle cx="12" cy="12" r="3" />
                    {showConfirm && <path d="m3 3 18 18" />}
                  </svg>
                </button>
              </div>
            )}
            <button class="primary" disabled={busy}>
              {busy ? t("请稍候…") : state.exists ? t("解锁") : t("创建资料库")}
            </button>
          </section>
        </form>
      ) : (
        <>
          {state.mode === "native" &&
            (!state.available || !state.unlocked || !state.paired) && !state.syncSupported && !captured && (
              <NativeConnectionPanel
                state={state}
                busy={busy}
                onOpen={openMac}
                onPair={() => run(() => message({ action: "pair" }))}
                onRefresh={() => run(async () => {})}
              />
            )}
          {state.mode === "native" && state.syncSupported && !captured && (
            <BackgroundSyncPanel ready={state.syncReady} readReady={state.readReady} readsLocked={state.readsLocked}
              autoUnlockReady={state.autoUnlockReady} busy={busy}
              onConfigure={(password, autoUnlock) => run(() => message({ action: "configure-sync", password, allowRead:true, autoUnlock }))}
              onDisableAuto={() => run(() => message({action:"disable-auto-unlock"}))}
              onDisable={() => run(() => message({ action: "disable-sync" }))} />
          )}
          {state.mode === "native" && state.syncSupported && !captured && (!state.unlocked || !state.paired) && (
            <details>
              <summary>{t("读取和填充已有账号")}</summary>
              <NativeConnectionPanel state={state} busy={busy}
                onOpen={openMac}
                onPair={() => run(() => message({ action: "pair" }))}
                onRefresh={() => run(async () => {})} />
            </details>
          )}
          {state.mode === "native" && !captured && (
            <div class={`sync-count ${syncTone(state)}`} role="status" aria-live="polite">
              <span>
                {state.queued
                  ? fmt(t("{queued} 个账号待同步到 Mac 客户端"),{"queued":state.queued})
                  : state.available === false
                    ? t("Mac 客户端未连接 · 没有待同步的账号")
                    : t("已全部同步到 Mac 客户端")}
              </span>
              {!!state.queued && (
                <button class="text-button" type="button" disabled={busy || syncing} onClick={() => { setSyncing(true); void run(async () => {}).finally(() => setSyncing(false)); }}>
                  {syncing ? t("正在同步…") : t("立即同步")}
                </button>
              )}
            </div>
          )}
          {state.mode === "native" && (
            <p class="muted" role="status">
              {captured ? (state.queued ? fmt(t("已暂存 {queued} 个账号，确认后加入同步队列。"),{"queued":state.queued}) : state.syncReady ? t("后台保存已开启。") : t("支持离线保存，账号会加密暂存。")) : state.queued
                ? fmt(state.syncReady ? t("已在此浏览器暂存 {queued} 个账号，将自动同步到 Mac。") : t("已在此浏览器暂存 {queued} 个账号，配置后台保存或连接并解锁 Mac 后自动同步。"),{queued:state.queued})
                : state.readReady ? t("可直接查看和填充本站账号。") : state.syncReady ? t("后台保存已就绪，Mac 应用退出后仍可同步。") : t("支持离线保存，配置后台保存或连接并解锁 Mac 后自动同步。")}
              {state.syncError && t("同步未完成，将自动重试。")}
            </p>
          )}
          <div class="section-title">
            <span>{t("当前网站")}</span>
            {!nativeDisconnected && (
              <button
                class="text-button"
                onClick={() =>
                  run(async () => {
                    await lock();
                    setCaptured(undefined);
                  })
                }
              >
                {t("锁定")}
              </button>
            )}
          </div>
          <p class="origin">{matches?.origin ?? t("请打开一个网站")}</p>
          {captured && (
            <CaptureConfirmation
              key={`${captured.tabId}:${captured.origin}:${captured.id ?? "manual"}`}
              captured={captured}
              accounts={matches?.accounts ?? []}
              busy={busy}
              error={error}
              onChange={setCaptured}
              onSave={() =>
                run(async () => {
                  const result = await message({
                    action: "save-captured",
                    ...captured,
                  });
                  setCaptured(undefined);
                  setNotice(
                    result.queued
                      ? t("已加密暂存在此浏览器，后台保存可用时自动重试。")
                      : t("账号已保存。"),
                  );
                })
              }
              onCancel={() =>
                run(async () => {
                  if (captured.expires)
                    await message({
                      action: "dismiss-pending",
                      tabId: captured.tabId,
                      origin: captured.origin,
                      id: captured.id,
                    });
                  setCaptured(undefined);
                  setNotice(t("已取消保存。"), "muted");
                })
              }
            />
          )}
          {notice && <p class={noticeTone === "ok" ? "notice-ok" : "notice-muted"} role="status">{notice}</p>}
          {matchesError && (
            <p class="empty-small" role="status">
              {matchesError}
            </p>
          )}
          <details
            class="site-accounts"
            open={!captured}
            key={captured ? "pending-accounts" : "accounts"}
          >
            <summary>{fmt(t("已保存账号（{count}）"),{count:matches?.accounts?.length ?? 0})}</summary>
            <div class="match-list">
              {matches?.accounts?.length
                ? matches.accounts.map((account: any) => (
                    <div
                      class="match-row"
                      key={account.id + (account.accountId ?? "")}
                    >
                      <button
                        class="match"
                        disabled={busy}
                        title={
                          state.mode === "native" && !state.readReady ? t("在 Mac 中编辑") : t("填充账号")
                        }
                        aria-label={fmt(state.mode === "native" && !state.readReady ? t("在 Mac 中编辑：{title} {username}") : t("填充账号：{title} {username}"),{title:account.title,username:account.username || ""})}
                        onClick={() =>
                          run(async () => {
                            if (state.mode === "native" && !state.readReady) {
                              await message({
                                action: "edit-native-entry",
                                tabId: matches.id,
                                origin: matches.origin,
                                id: account.id,
                                accountId: account.accountId,
                              });
                              setNotice(t("已在 Mac 中打开该账号，可继续编辑。"));
                            } else {
                              await message({
                                action: "fill",
                                tabId: matches.id,
                                origin: matches.origin,
                                id: account.id,
                                accountId: account.accountId,
                              });
                              if (sourceTabId !== undefined)
                                await chrome.tabs.update(sourceTabId, {
                                  active: true,
                                });
                              window.close();
                            }
                          })
                        }
                      >
                        <span class={`tile tone-${tileFor(account.title).tone}`} aria-hidden="true">{tileFor(account.title).initial}</span>
                        <span>
                          <strong>{account.title}</strong>
                          <small>{account.username || t("未填写账号")}</small>
                          {state.mode === "native" && !state.readReady && (
                            <small class="edit-in-mac">{t("在 Mac 中编辑 ↗")}</small>
                          )}
                        </span>
                      </button>
                      {state.mode === "native" && (
                        <button
                          class="match-fill"
                          disabled={busy}
                          aria-label={fmt(t("填充账号：{title} {username}"),{title:account.title,username:account.username || ""})}
                          onClick={() =>
                            run(async () => {
                              await message({
                                action: "fill",
                                tabId: matches.id,
                                origin: matches.origin,
                                id: account.id,
                                accountId: account.accountId,
                              });
                              if (sourceTabId !== undefined)
                                await chrome.tabs.update(sourceTabId, {
                                  active: true,
                                });
                              window.close();
                            })
                          }
                        >
                          {t("填充")}
                        </button>
                      )}
                      <AccountSecret account={account} origin={matches.origin} tabId={matches.id} disabled={busy} />
                      <button type="button" class="text-button" disabled={busy}
                        onClick={() => run(async () => {
                          const value = await message({action:"reveal-account",tabId:matches.id,origin:matches.origin,id:account.id,accountId:account.accountId});
                          setCaptured({tabId:matches.id,origin:matches.origin,mode:state.mode,username:value.username,password:value.password,updateId:account.id,updateAccountId:account.accountId});
                          value.password = "";
                        })}>{t("修改账号密码")}</button>
                    </div>
                  ))
                : !matchesError && (
                    <p class="empty-small">{t("此网站还没有保存的账号")}</p>
                  )}
            </div>
          </details>
          {!captured && (
            <div class="popup-secondary-actions">
              <button
                class={matches?.accounts?.length ? "" : "primary"}
                disabled={busy || !matches}
                onClick={() => {
                  revision.current++;
                  setCaptured({
                    tabId: matches.id,
                    origin: matches.origin,
                    mode: state.mode,
                    manual: true,
                    username: "",
                    password: "",
                  });
                }}
              >
                {t("添加账号密码")}
              </button>
              <button
                disabled={busy || !matches}
                onClick={() =>
                  run(async () =>
                    setCaptured(
                      await message({ action: "capture", tabId: matches.id }),
                    ),
                  )
                }
              >
                {t("保存网页中的账号")}
              </button>
            </div>
          )}
          {!captured && !nativeDisconnected && <StructuredFill/>}
          {matches && (
            <div class="reminder-setting">
              <button
                class="text-button"
                disabled={busy}
                onClick={() => {
                  const target = { tabId: matches.id, origin: matches.origin };
                  void run(async () => {
                    await message({
                      action: "configure-reminder",
                      ...target,
                      enabled: !matches.reminders,
                    });
                    setNotice(
                      matches.reminders
                        ? t("已关闭此网站的登录提醒。")
                        : t("已开启。下次提交登录后会提示保存。"),
                    );
                  });
                }}
              >
                {matches.reminders
                  ? t("关闭此网站的登录提醒")
                  : t("启用此网站的登录提醒")}
              </button>
              <small class="muted">
                {t("默认在所有网站提醒，可单独关闭本站；保存前仍需确认。")}
              </small>
            </div>
          )}
        </>
      )}
      {state && !creatingIndependent && (<details class="authorization-settings">
            <summary>{t("自动锁定")}{state.autoLockEnabled ? fmt(t(" · {hours} 小时"),{hours:state.autoLockMinutes / 60}) : t(" · 未开启")}</summary>
            <label class="authorization-option">
              <input id="browser-auto-lock" type="checkbox" checked={state.autoLockEnabled === true} disabled={busy}
                onChange={(event) => { const enabled = event.currentTarget.checked; void run(() => message({action:"configure-auto-lock", enabled, minutes:state.autoLockMinutes ?? 60})); }} />
              {t("空闲后需要重新输入主密码")}
            </label>
            {state.autoLockEnabled && <div class="seg-group"><span class="seg-label">{t("空闲时长")}</span>
              <div id="browser-auto-lock-minutes" class="seg-bar" role="radiogroup" aria-label={t("空闲时长")}>
                {([[60, t("1 小时")], [120, t("2 小时")]] as const).map(([minutes, label]) => {
                  const active = (state.autoLockMinutes ?? 60) === minutes;
                  return <button type="button" role="radio" aria-checked={active} class={active ? "on" : ""} disabled={busy}
                    onClick={() => void run(() => message({action:"configure-auto-lock", enabled:true, minutes}))}>{label}</button>;
                })}
              </div>
            </div>}
            <p class="muted">{t("默认保持授权，不因空闲或电脑锁屏要求重新输入。开启后，达到所选空闲时长或电脑锁屏时锁定插件。手动锁定、撤销授权或修改主密码后仍需验证。")}</p>
          </details>)}
      <footer class="popup-footer">
        <span>{creatingIndependent ? t("加密保存在本地浏览器") : state?.autoLockEnabled ? fmt(t("空闲 {hours} 小时后锁定"),{hours:state.autoLockMinutes / 60}) : t("自动锁定未开启")}</span>
        <button class="text-button" onClick={manage}>
          {t("管理资料库 ↗")}
        </button>
      </footer>
    </main>
  );
}

function CaptureConfirmation({
  captured,
  accounts,
  busy,
  error,
  onChange,
  onSave,
  onCancel,
}: {
  captured: any;
  accounts: any[];
  busy: boolean;
  error: string;
  onChange: (value: any) => void;
  onSave: () => void;
  onCancel: () => void;
}) {
  const [revealed, setRevealed] = useState(false);
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    form.current?.scrollIntoView({ block: "nearest" });
    const conceal = () => setRevealed(false);
    window.addEventListener("blur", conceal);
    document.addEventListener("visibilitychange", conceal);
    return () => {
      window.removeEventListener("blur", conceal);
      document.removeEventListener("visibilitychange", conceal);
    };
  }, []);
  return (
    <form
      ref={form}
      class="capture"
      aria-label={captured.updateId ? t("修改账号密码") : captured.manual ? t("添加账号密码") : t("确认保存账号")}
      onSubmit={(event) => {
        event.preventDefault();
        setRevealed(false);
        onSave();
      }}
    >
      <h3>{captured.updateId ? t("修改账号密码") : captured.manual ? t("添加账号密码") : t("确认保存账号")}</h3>
      <p class="muted capture-hint">
        {captured.manual ? t("为当前网站填写账号和密码。") : t("可修改后保存。")}
        {captured.mode === "native" ? t("离线暂存使用此浏览器的设备密钥加密。") : t("数据加密保存在此浏览器的独立资料库中。")}
        {captured.expires ? t("待保存信息将在两分钟后清除。") : t("确认后加密保存。")}
      </p>
      {accounts.length <= 5 ? (
        <div class="seg-group">
          <span class="seg-label">{t("保存方式")}</span>
          <div class="pick-cards" role="radiogroup" aria-label={t("保存方式")}>
            <button type="button" role="radio" aria-checked={!captured.updateId} class={`pick-card${!captured.updateId ? " on" : ""}`} disabled={busy}
              onClick={() => onChange({ ...captured, updateId: undefined, updateAccountId: undefined })}>
              <span class="dot" /><span><b>{t("另存为新账号")}</b></span>
            </button>
            {accounts.map(account => {
              const val = JSON.stringify([account.id, account.accountId ?? null]);
              const active = (captured.updateId ? JSON.stringify([captured.updateId, captured.updateAccountId ?? null]) : "") === val;
              return (
                <button type="button" role="radio" aria-checked={active} class={`pick-card${active ? " on" : ""}`} disabled={busy}
                  onClick={() => onChange({ ...captured, updateId: account.id, updateAccountId: account.accountId ?? undefined, username: account.username ?? captured.username })}>
                  <span class="dot" /><span><b>{fmt(t("更新：{title} · {username}"), { title: account.title, username: account.username })}</b></span>
                </button>
              );
            })}
          </div>
        </div>
      ) : (
        <label>{t("保存方式")}<select disabled={busy} value={captured.updateId ? JSON.stringify([captured.updateId,captured.updateAccountId ?? null]) : ""} onChange={event=>{
          const value=event.currentTarget.value;
          const [updateId,updateAccountId]=value ? JSON.parse(value) : [undefined,undefined];
          const account=accounts.find(a=>a.id===updateId && (a.accountId??null)===(updateAccountId??null));
          onChange({...captured,updateId,updateAccountId:updateAccountId??undefined,username:account?.username??captured.username});
        }}><option value="">{t("另存为新账号")}</option>{accounts.map(account=><option value={JSON.stringify([account.id,account.accountId??null])}>{fmt(t("更新：{title} · {username}"),{title:account.title,username:account.username})}</option>)}</select></label>
      )}
      {captured.updateId && <p class="muted">{t("更新所选账号并保留旧密码历史；需要资料库在线解锁。")}</p>}
      <label htmlFor="capture-username">{t("账号")}</label>
      <input
        id="capture-username"
        required
        maxLength={4096}
        autoFocus={captured.manual}
        autoComplete="off"
        spellcheck={false}
        disabled={busy}
        value={captured.username}
        onInput={(event) =>
          onChange({ ...captured, username: event.currentTarget.value })
        }
      />
      <label htmlFor="capture-password">{t("密码")}</label>
      <div class="capture-secret">
        <input
          id="capture-password"
          required
          maxLength={4096}
          type={revealed ? "text" : "password"}
          autoComplete="off"
          spellcheck={false}
          autoCapitalize="off"
          disabled={busy}
          value={captured.password}
          onInput={(event) =>
            onChange({ ...captured, password: event.currentTarget.value })
          }
        />
        <button
          type="button"
          class="secret-toggle"
          disabled={busy}
          aria-label={revealed ? t("隐藏密码") : t("显示密码")}
          title={revealed ? t("隐藏密码") : t("显示密码")}
          aria-pressed={revealed}
          aria-controls="capture-password"
          onClick={() => setRevealed((value) => !value)}
        >
          <svg
            width="19"
            height="19"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.7"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z" />
            <circle cx="12" cy="12" r="3" />
            {revealed && <path d="m3 3 18 18" />}
          </svg>
        </button>
      </div>
      {error && (
        <p class="error" role="alert">
          {error}
        </p>
      )}
      <div class="actions">
        <button
          type="button"
          disabled={busy}
          onClick={() => {
            setRevealed(false);
            onCancel();
          }}
        >
          {t("取消保存")}
        </button>
        <button class="primary" disabled={busy}>
          {busy ? t("请稍候…") : t("保存")}
        </button>
      </div>
    </form>
  );
}

render(<><PasskeyApproval/><Popup /></>, document.getElementById("app")!);
