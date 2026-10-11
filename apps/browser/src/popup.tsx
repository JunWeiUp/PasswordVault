import { render } from "preact";
import { useEffect, useState, useRef } from "preact/hooks";
import { authenticate, errorText, message, status, lock } from "./client";
import { AccountSecret } from "./AccountSecret";
import { BackgroundSyncPanel } from "./BackgroundSyncPanel";
import { NativeConnectionPanel } from "./NativeConnectionPanel";
import { MAC_DOWNLOAD_URL } from "./native-connection";
import "./style.css";
import { version } from "../package.json";
function Popup() {
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
  const [matches, setMatches] = useState<any>();
  const [captured, setCaptured] = useState<any>();
  const [matchesError, setMatchesError] = useState("");
  const [notice, setNotice] = useState("");
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
          else setMatchesError(errorText(e));
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
      setError(errorText(e));
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
        void refresh().catch((e) => setError(errorText(e)));
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
  const manage = () =>
    chrome.tabs.create({ url: chrome.runtime.getURL("index.html") });
  return (
    <main class={`popup${captured ? " has-capture" : ""}`}>
      <header class="brand">
        <span class="brand-icon">
          <img src="./brand.png" alt="" width="30" height="30" />
        </span>
        <strong>PasswordVault</strong>
        <span class="brand-version" aria-label={`插件版本 ${version}`}>v{version}</span>
        <button class="icon-button mac-launch" title="打开 Mac 应用" aria-label="打开 Mac 应用" disabled={busy} onClick={openMac}>
          <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <rect x="3" y="3" width="18" height="13" rx="2" />
            <path d="M9 21h6M12 16v5M8 12l8-6M11 6h5v5" />
          </svg>
        </button>
      </header>
      {macOpenFailed && (
        <aside class="mac-download-notice" role="status">
          <p>未能打开 Mac 应用。尚未安装？请前往 GitHub 下载；已安装请在「设置 → 浏览器」重新登记连接。</p>
          <a href={MAC_DOWNLOAD_URL} target="_blank" rel="noopener noreferrer">前往 GitHub 下载 ↗</a>
          <button class="text-button" onClick={() => setMacOpenFailed(false)} aria-label="关闭下载提示">关闭</button>
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
          返回登录页面
        </button>
      )}
      <div class="mode-switch" aria-label="资料库模式">
        <button
          disabled={busy}
          aria-pressed={state?.mode === "native"}
          onClick={() => run(() => message({ action: "mode", mode: "native" }))}
        >
          连接 Mac
        </button>
        <button
          disabled={busy}
          aria-pressed={state?.mode === "independent"}
          onClick={() =>
            run(() => message({ action: "mode", mode: "independent" }))
          }
        >
          独立资料库
        </button>
      </div>
      {error && !captured && (
        <p class="error" role="alert">
          {error}
        </p>
      )}
      {!state ? (
        <section class="popup-empty">
          <p class="muted">{error ? "暂时无法读取连接状态" : "正在连接…"}</p>
          {error && !captured && (
            <button disabled={busy} onClick={() => run(async () => {})}>
              重新检测
            </button>
          )}
        </section>
      ) : state.mode !== "native" && !state.unlocked ? (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            const value = password;
            setPassword("");
            void run(() => authenticate(value, !state.exists));
          }}
        >
          <section class="popup-empty">
            <span class="lock-symbol">⌑</span>
            <h2>{state.exists ? "解锁资料库" : "创建独立资料库"}</h2>
            <p>
              {state.exists
                ? "使用主密码继续。"
                : "数据加密保存在此浏览器。请记住主密码。"}
            </p>
            <input
              autoFocus
              type="password"
              autoComplete={state.exists ? "current-password" : "new-password"}
              minLength={state.exists ? 1 : 10}
              required
              placeholder={
                state.exists ? "主密码" : "设置主密码（至少 10 字符）"
              }
              value={password}
              onInput={(e) => setPassword(e.currentTarget.value)}
            />
            <button class="primary" disabled={busy}>
              {busy ? "请稍候…" : state.exists ? "解锁" : "创建资料库"}
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
              <summary>读取和填充已有账号</summary>
              <NativeConnectionPanel state={state} busy={busy}
                onOpen={openMac}
                onPair={() => run(() => message({ action: "pair" }))}
                onRefresh={() => run(async () => {})} />
            </details>
          )}
          {state.mode === "native" && (
            <p class="muted" role="status">
              {captured ? (state.queued ? `已暂存 ${state.queued} 个账号，确认后加入同步队列。` : state.syncReady ? "后台保存已开启。" : "支持离线保存，账号会加密暂存。") : state.queued
                ? `已在此浏览器暂存 ${state.queued} 个账号，${state.syncReady ? "将自动同步到 Mac。" : "配置后台保存或连接并解锁 Mac 后自动同步。"}`
                : state.readReady ? "可直接查看和填充本站账号。" : state.syncReady ? "后台保存已就绪，Mac 应用退出后仍可同步。" : "支持离线保存，配置后台保存或连接并解锁 Mac 后自动同步。"}
              {state.syncError && "同步未完成，将自动重试。"}
            </p>
          )}
          <div class="section-title">
            <span>当前网站</span>
            <button
              class="text-button"
              onClick={() =>
                run(async () => {
                  await lock();
                  setCaptured(undefined);
                })
              }
            >
              锁定
            </button>
          </div>
          <p class="origin">{matches?.origin ?? "请打开一个网站"}</p>
          {!captured && (
            <button
              class="primary wide"
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
              添加账号密码
            </button>
          )}
          {captured && (
            <CaptureConfirmation
              key={`${captured.tabId}:${captured.origin}:${captured.id ?? "manual"}`}
              captured={captured}
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
                      ? "已加密暂存在此浏览器，后台保存可用时自动重试。"
                      : "账号已保存。",
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
                  setNotice("已取消保存。");
                })
              }
            />
          )}
          {notice && <p role="status">{notice}</p>}
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
            <summary>已保存账号（{matches?.accounts?.length ?? 0}）</summary>
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
                          state.mode === "native" && !state.readReady ? "在 Mac 中编辑" : "填充账号"
                        }
                        aria-label={`${state.mode === "native" && !state.readReady ? "在 Mac 中编辑" : "填充账号"}：${account.title} ${account.username || ""}`}
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
                              setNotice("已在 Mac 中打开该账号，可继续编辑。");
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
                        <span class="record-symbol">⌘</span>
                        <span>
                          <strong>{account.title}</strong>
                          <small>{account.username || "未填写账号"}</small>
                          {state.mode === "native" && !state.readReady && (
                            <small class="edit-in-mac">在 Mac 中编辑 ↗</small>
                          )}
                        </span>
                      </button>
                      {state.mode === "native" && (
                        <button
                          class="match-fill"
                          disabled={busy}
                          aria-label={`填充账号：${account.title} ${account.username || ""}`}
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
                          填充
                        </button>
                      )}
                      <AccountSecret account={account} origin={matches.origin} tabId={matches.id} disabled={busy} />
                    </div>
                  ))
                : !matchesError && (
                    <p class="empty-small">此网站还没有保存的账号</p>
                  )}
            </div>
          </details>
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
                        ? "已关闭此网站的登录提醒。"
                        : "已开启。下次提交登录后会提示保存。",
                    );
                  });
                }}
              >
                {matches.reminders
                  ? "关闭此网站的登录提醒"
                  : "启用此网站的登录提醒"}
              </button>
              <small class="muted">
                默认在所有网站提醒，可单独关闭本站；保存前仍需确认。
              </small>
            </div>
          )}
          {!captured && (
            <button
              class="wide"
              disabled={busy || !matches}
              onClick={() =>
                run(async () =>
                  setCaptured(
                    await message({ action: "capture", tabId: matches.id }),
                  ),
                )
              }
            >
              保存网页中的账号
            </button>
          )}
        </>
      )}
      <footer class="popup-footer">
        <span>自动锁定</span>
        <button class="text-button" onClick={manage}>
          管理资料库 ↗
        </button>
      </footer>
    </main>
  );
}

function CaptureConfirmation({
  captured,
  busy,
  error,
  onChange,
  onSave,
  onCancel,
}: {
  captured: any;
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
      aria-label={captured.manual ? "添加账号密码" : "确认保存账号"}
      onSubmit={(event) => {
        event.preventDefault();
        setRevealed(false);
        onSave();
      }}
    >
      <h3>{captured.manual ? "添加账号密码" : "确认保存账号"}</h3>
      <p class="muted capture-hint">
        {captured.manual ? "为当前网站填写账号和密码。" : "可修改后保存。"}
        离线暂存使用此浏览器的设备密钥加密。
        {captured.expires ? "待保存信息将在两分钟后清除。" : "确认后加密保存。"}
      </p>
      <label htmlFor="capture-username">账号</label>
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
      <label htmlFor="capture-password">密码</label>
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
          aria-label={revealed ? "隐藏密码" : "显示密码"}
          title={revealed ? "隐藏密码" : "显示密码"}
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
          取消保存
        </button>
        <button class="primary" disabled={busy}>
          {busy ? "请稍候…" : "保存"}
        </button>
      </div>
    </form>
  );
}

render(<Popup />, document.getElementById("app")!);
