import { render } from "preact";
import { useEffect, useState, useRef } from "preact/hooks";
import { authenticate, errorText, message, status, lock } from "./client";
import { NativeConnectionPanel } from "./NativeConnectionPanel";
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
      if (s.unlocked && (s.mode !== "native" || s.paired)) {
        try {
          const found = await message({
            action: "matches",
            tabId: sourceTabId,
          });
          if (generation !== revision.current) return;
          setMatches(found);
          setCaptured((old: any) => {
            if (old && (old.origin !== found.origin || old.tabId !== found.id))
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
  const manage = () =>
    chrome.tabs.create({ url: chrome.runtime.getURL("index.html") });
  return (
    <main class={`popup${captured ? " has-capture" : ""}`}>
      <header class="brand">
        <span class="brand-icon">
          <img src="./brand.png" alt="" width="30" height="30" />
        </span>
        <strong>PasswordVault</strong>
        <button class="icon-button" title="打开资料库" onClick={manage}>
          ↗
        </button>
      </header>
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
      {!state ? (
        <section class="popup-empty">
          <p class="muted">{error ? "暂时无法读取连接状态" : "正在连接…"}</p>
          {error && !captured && (
            <button disabled={busy} onClick={() => run(async () => {})}>
              重新检测
            </button>
          )}
        </section>
      ) : state.mode === "native" &&
        (!state.available || !state.unlocked || !state.paired) ? (
        <NativeConnectionPanel
          state={state}
          busy={busy}
          onOpen={() => run(() => message({ action: "open-native" }))}
          onPair={() => run(() => message({ action: "pair" }))}
          onRefresh={() => run(async () => {})}
        />
      ) : !state.unlocked ? (
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
          <div class="section-title">
            <span>当前网站</span>
            <button class="text-button" onClick={() => run(lock)}>
              锁定
            </button>
          </div>
          <p class="origin">{matches?.origin ?? "请打开一个网站"}</p>
          {captured && (
            <CaptureConfirmation
              key={`${captured.tabId}:${captured.origin}:${captured.id ?? "manual"}`}
              captured={captured}
              busy={busy}
              error={error}
              onChange={setCaptured}
              onSave={() =>
                run(async () => {
                  await message({ action: "save-captured", ...captured });
                  setCaptured(undefined);
                  setNotice("账号已保存，可以清空网页表单后测试填充。");
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
                          state.mode === "native" ? "在 Mac 中编辑" : "填充账号"
                        }
                        aria-label={`${state.mode === "native" ? "在 Mac 中编辑" : "填充账号"}：${account.title} ${account.username || ""}`}
                        onClick={() =>
                          run(async () => {
                            if (state.mode === "native") {
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
                          {state.mode === "native" && (
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
                    </div>
                  ))
                : !matchesError && (
                    <p class="empty-small">此网站还没有保存的账号</p>
                  )}
            </div>
          </details>
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
      {error && !captured && (
        <p class="error" role="alert">
          {error}
        </p>
      )}
      <footer class="popup-footer">
        <span>v{version} · 自动锁定</span>
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
      aria-label="确认保存账号"
      onSubmit={(event) => {
        event.preventDefault();
        setRevealed(false);
        onSave();
      }}
    >
      <h3>确认保存账号</h3>
      <p class="muted capture-hint">
        可修改后保存。
        {captured.expires ? "待保存信息将在两分钟后清除。" : "确认后加密保存。"}
      </p>
      <label htmlFor="capture-username">账号</label>
      <input
        id="capture-username"
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
