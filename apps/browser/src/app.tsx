import { t, fmt, dateLocale, useLocale, setLocale, setTheme } from "./i18n";
import { tileFor } from "./tiles";
import { render } from "preact";
import { useEffect, useLayoutEffect, useState, useRef } from "preact/hooks";
import {
  authenticate,
  command,
  errorText,
  isExtension,
  lock,
  message,
  status,
} from "./client";
import { NativeConnectionPanel } from "./NativeConnectionPanel";
import { RecoveryDialog } from "./RecoveryPanel";
import { PasskeyDetails } from "./PasskeyDetails";
import { RichNoteEditor, flushRichNote } from "./RichNoteEditor";
import { HistoryDialog } from "./HistoryDialog";
import { structuredLabel } from "./Capabilities";
import { Code, Field, type Item, Markdown, NavIcon } from "./app/components";
import { Editor } from "./app/Editor";
import { Tools } from "./app/Tools";
import "./style.css";

const sections = [
  ["secureNote", "笔记", "note"],
  ["password", "账号", "key"],
  ["totp", "验证码", "clock"],
  ["crypto", "钱包", "wallet"],
  ["creditCard", "银行卡", "card"],
  ["identity", "身份资料", "user"],
] as const;

function App() {
  useLocale();
  const [state, setState] = useState<any>();
  const [doc, setDoc] = useState<any>();
  const [section, setSection] = useState("secureNote");
  function canEditItem(value:Item) {
    if(!value.sharedVaultId)return true;
    const own=doc?.settings?.sharingIdentity?.publicKey;
    return !!own && !!doc?.sharedMembers?.some((member:any)=>member.vaultId===value.sharedVaultId&&member.userPublicKey===own&&["owner","editor"].includes(member.role));
  }
  const [category, setCategory] = useState("");
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState("");
  const [editing, setEditing] = useState<Item>();
  const [recoveredDraft, setRecoveredDraft] = useState<Item>();
  const pendingDraft = useRef<Item>();
  const draftTimer = useRef<ReturnType<typeof setTimeout>>();
  const draftWrite = useRef<Promise<unknown>>(Promise.resolve());
  const [draftStatus, setDraftStatus] = useState<"idle" | "saving" | "saved" | "failed">("idle");
  async function persistDraft() {
    clearTimeout(draftTimer.current);
    const value = pendingDraft.current;
    if (!value) return;
    draftWrite.current = draftWrite.current
      .catch(() => {})
      .then(() => command({ op: "draft-save", item: value }));
    try { await draftWrite.current; } catch (e) { setDraftStatus("failed"); throw e; }
    if (pendingDraft.current === value) setDraftStatus("saved");
    if (pendingDraft.current?.id === value.id) setRecoveredDraft(value);
  }
  function changedDraft(value: Item) {
    pendingDraft.current = value;
    setDraftStatus("saving");
    clearTimeout(draftTimer.current);
    draftTimer.current = setTimeout(() => {
      void persistDraft().catch((e) => setError(t(errorText(e))));
    }, 250);
  }
  async function flushDraft() {
    if (editing) {
      const latest = await flushRichNote(editing.id);
      if (latest)
        pendingDraft.current = {
          ...(pendingDraft.current ?? editing),
          note: latest.note,
          noteFormat: latest.noteFormat,
          noteDocument: latest.noteDocument,
          ...(latest.noteOriginal ? { noteOriginal: latest.noteOriginal } : {}),
        };
    }
    await persistDraft();
  }
  async function lockWithDraft() {
    await flushDraft();
    await lock();
    pendingDraft.current = undefined;
    setRecoveredDraft(undefined);
    setDoc(undefined);
    setEditing(undefined);
  }
  useEffect(() => {
    const leave = (e: BeforeUnloadEvent) => {
      if (pendingDraft.current) {
        void persistDraft().catch(() => {});
        e.preventDefault();
        e.returnValue = "";
      }
    };
    const hide = () => {
      if (document.visibilityState === "hidden")
        void persistDraft().catch(() => {});
    };
    addEventListener("beforeunload", leave);
    document.addEventListener("visibilitychange", hide);
    return () => {
      clearTimeout(draftTimer.current);
      removeEventListener("beforeunload", leave);
      document.removeEventListener("visibilitychange", hide);
    };
  }, []);
  useLayoutEffect(() => {
    if (editing) changedDraft(editing);
  }, [editing?.id]);
  const [history, setHistory] = useState<string>();
  const [recovering, setRecovering] = useState(false);
  const actionBusy = useRef(false);
  const polling = useRef(false);
  const generation = useRef(0);
  useEffect(() => {
    if (!doc) {
      setHistory(undefined);
    } else setRecovering(false);
  }, [!!doc]);
  async function refresh() {
    const s = await status();
    setState(s);
    if (s.unlocked && s.mode === "independent") {
      const data = await command({ op: "list" });
      setDoc(data);
      const draft = await command({ op: "draft-read" });
      setRecoveredDraft(draft.item ?? undefined);
      if (["zh", "en"].includes(data.settings?.language))
        setLocale(data.settings.language);
      if (["light", "dark", "system"].includes(data.settings?.theme))
        setTheme(data.settings.theme);
    } else {
      setDoc(undefined);
      clearTimeout(draftTimer.current);
      pendingDraft.current = undefined;
      setRecoveredDraft(undefined);
      setEditing(undefined);
      setHistory(undefined);
    }
  }
  async function run(work: () => Promise<unknown>) {
    if (actionBusy.current) return;
    actionBusy.current = true;
    generation.current++;
    setBusy(true);
    setError("");
    try {
      await work();
    } catch (e) {
      setError(t(errorText(e)));
      await refresh().catch(() => {});
    } finally {
      actionBusy.current = false;
      setBusy(false);
    }
  }
  useEffect(() => {
    void run(refresh);
    const timer = setInterval(() => {
      if (actionBusy.current || polling.current) return;
      polling.current = true;
      const version = generation.current;
      void status()
        .then((s) => {
          if (version !== generation.current || actionBusy.current) return;
          setState(s);
          if (!s.unlocked) {
            setDoc(undefined);
            clearTimeout(draftTimer.current);
            pendingDraft.current = undefined;
            setRecoveredDraft(undefined);
            setEditing(undefined);
            setHistory(undefined);
          }
        })
        .catch((e) => {
          if (version === generation.current) setError(t(errorText(e)));
        })
        .finally(() => {
          polling.current = false;
        });
    }, 2000);
    return () => {
      generation.current++;
      clearInterval(timer);
    };
  }, []);
  useEffect(() => {
    let last = 0;
    const activity = () => {
      if (Date.now() - last < 15_000) return;
      last = Date.now();
      void command({ op: "activity" }).catch(() => {});
    };
    document.addEventListener("keydown", activity);
    document.addEventListener("pointerdown", activity);
    return () => {
      document.removeEventListener("keydown", activity);
      document.removeEventListener("pointerdown", activity);
    };
  }, []);
  useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(""), 2200);
    return () => clearTimeout(id);
  }, [toast]);
  const items: Item[] = doc?.items ?? [];
  const visible = items
    .filter(
      (item) =>
        (section === "trash"
          ? item.isDeleted
          : !item.isDeleted && item.type === section) &&
        (!category || item.category === category) &&
        [item.title, item.username, item.note, ...(item.tags ?? [])]
          .filter(Boolean)
          .join(" ")
          .toLowerCase()
          .includes(search.toLowerCase()),
    )
    .sort(
      (a, b) =>
        Number(!!b.isPinned) - Number(!!a.isPinned) ||
        Number(!!b.isFavorite) - Number(!!a.isFavorite) ||
        (b.updatedAt ?? "").localeCompare(a.updatedAt ?? ""),
    );
  const item = visible.find((v) => v.id === selected) ?? visible[0];
  const categories = [
    ...new Set(
      items
        .filter((v) => v.type === "secureNote" && !v.isDeleted)
        .map((v) => v.category)
        .filter(Boolean),
    ),
  ];
  async function save(value: Item, commitDraft = false) {
    await command({
      op: "save",
      richNotes: true,
      item: { ...value, updatedAt: new Date().toISOString() },
    });
    if (commitDraft && pendingDraft.current?.id === value.id) {
      clearTimeout(draftTimer.current);
      await draftWrite.current.catch(() => {});
      await command({ op: "draft-clear" });
      pendingDraft.current = undefined;
      setRecoveredDraft(undefined);
    }
    setSelected(value.id);
    await refresh();
    setEditing(undefined);
    setToast(t("已保存"));
  }
  function leaveEditor(action: () => void) {
    if (editing) void run(async () => { await flushDraft(); action(); });
    else action();
  }
  function navigate(next: string) {
    leaveEditor(() => {
      setSection(next); setCategory(""); setSearch(""); setEditing(undefined);
    });
  }
  function newItem() {
    if (pendingDraft.current || recoveredDraft) {
      setError(t("请先保存或丢弃现有草稿"));
      return;
    }
    setEditing({
      id: crypto.randomUUID(),
      type: section,
      ...(section === "creditCard"
        ? { card: {} }
        : section === "identity"
          ? { identity: {} }
          : {}),
      title: "",
      username: "",
      note: "",
      noteFormat: "markdown",
      category,
      createdAt: new Date().toISOString(),
    });
  }
  async function copy(value: string) {
    await run(async () => {
      await navigator.clipboard.writeText(value);
      setToast(t("已复制"));
    });
  }
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || !doc) return;
      if (event.key.toLowerCase() === "k") {
        event.preventDefault();
        document
          .querySelector<HTMLInputElement>("input[data-vault-search]")
          ?.focus();
      } else if (event.key.toLowerCase() === "l") {
        event.preventDefault();
        void run(async () => {
          await lockWithDraft();
        });
      }
    };
    document.addEventListener("keydown", shortcut);
    return () => document.removeEventListener("keydown", shortcut);
  }, [doc]);
  const brand = (
    <div class="brand">
      <span class="brand-icon">
        <img src="./brand.png" alt="" width="30" height="30" />
      </span>
      <strong>PasswordVault</strong>
    </div>
  );
  if (!state)
    return (
      <div class="unlock-page">
        {brand}
        {error ? (
          <>
            <p class="error" role="alert">
              {error}
            </p>
            <button disabled={busy} onClick={() => run(refresh)}>
              {t("重新尝试")}
            </button>
          </>
        ) : (
          <p class="muted">{t("正在打开资料库…")}</p>
        )}
      </div>
    );
  if (state.mode === "native")
    return (
      <div class="unlock-page">
        <div class="unlock-card">
          {brand}
          <NativeConnectionPanel
            state={state}
            busy={busy}
            onOpen={() =>
              run(async () => {
                await message({ action: "open-native" });
                await refresh();
              })
            }
            onPair={() =>
              run(async () => {
                await message({ action: "pair" });
                await refresh();
              })
            }
            onRefresh={() => run(refresh)}
          />
          <button
            disabled={busy}
            onClick={() =>
              run(async () => {
                await message({ action: "mode", mode: "independent" });
                await refresh();
              })
            }
          >
            {t("使用独立浏览器资料库")}
          </button>
          {error && <p class="error">{error}</p>}
        </div>
      </div>
    );
  if (!doc)
    return (
      <div class="unlock-page">
        <form
          class="unlock-card"
          onSubmit={(e) => {
            e.preventDefault();
            if (!state.exists && password !== confirm) {
              setError(t("两次输入的主密码不一致。"));
              return;
            }
            const value = password;
            setPassword("");
            setConfirm("");
            void run(async () => {
              await authenticate(value, !state.exists);
              await refresh();
            });
          }}
        >
          {brand}
          <span class="lock-symbol">⌑</span>
          <h1>{state.exists ? t("欢迎回来") : t("留下重要的资料")}</h1>
          <p>
            {state.exists
              ? t("解锁后继续整理你的笔记和账号。")
              : t("请保存恢复密钥和应急备份，未配置时无法重设忘记的主密码。")}
          </p>
          <label>
            {t("主密码")}
            <input
              autoFocus
              required
              minLength={state.exists ? 1 : 10}
              type="password"
              autoComplete={state.exists ? "current-password" : "new-password"}
              placeholder={t("至少 10 个字符")}
              value={password}
              onInput={(e) => setPassword(e.currentTarget.value)}
            />
          </label>
          {!state.exists && (
            <label>
              {t("再次输入")}
              <input
                required
                type="password"
                autoComplete="new-password"
                value={confirm}
                onInput={(e) => setConfirm(e.currentTarget.value)}
              />
            </label>
          )}
          <button class="primary" disabled={busy}>
            {busy
              ? t("正在解锁…")
              : state.exists
                ? t("解锁资料库")
                : t("创建资料库")}
          </button>
          {isExtension && (
            <button
              type="button"
              onClick={() =>
                run(async () => {
                  await message({ action: "mode", mode: "native" });
                  await refresh();
                })
              }
            >
              {t("连接 Mac 资料库")}
            </button>
          )}
          {error && (
            <p class="error" role="alert">
              {error}
            </p>
          )}
          <small>{t("本地保存 · 自动锁定")}</small>
          <button type="button" onClick={() => setRecovering(true)}>
            {t("使用恢复密钥")}
          </button>
        </form>
        {recovering && (
          <RecoveryDialog
            exists={state.exists}
            close={() => setRecovering(false)}
            onComplete={async () => {
              setRecovering(false);
              await refresh();
            }}
            copy={copy}
          />
        )}
      </div>
    );
  return (
    <main class="workspace">
      <aside class="sidebar">
        {recoveredDraft && !editing && (
          <section role="status">
            <p>{t("有未保存的加密草稿")}</p>
            <button
              onClick={() => {
                const draft = { ...recoveredDraft };
                navigate(draft.type);
                setEditing(draft);
                pendingDraft.current = draft;
              }}
            >
              {t("继续编辑草稿")}
            </button>
            <button
              onClick={() => {
                if (!window.confirm(t("永久丢弃此草稿？"))) return;
                void run(async () => {
                  clearTimeout(draftTimer.current);
                  await draftWrite.current.catch(() => {});
                  await command({ op: "draft-clear" });
                  pendingDraft.current = undefined;
                  setRecoveredDraft(undefined);
                });
              }}
            >
              {t("丢弃草稿")}
            </button>
          </section>
        )}

        {brand}
        <div class="sidebar-caption" role="status">{t("个人资料库")}</div>
        <div class="sidebar-caption">{t("资料库")}</div>
        <nav>
          {sections.map(([key, label, icon]) => (
            <button
              class={section === key ? "selected" : ""}
              onClick={() => navigate(key)}
            >
              <span class="nav-symbol"><NavIcon name={icon} /></span>
              {t(label)}
              <span class="count">
                {items.filter((i) => i.type === key && !i.isDeleted).length}
              </span>
            </button>
          ))}
        </nav>
        <div class="sidebar-caption">{t("笔记分类")}</div>
        <nav>
          <button
            class={section === "secureNote" && !category ? "selected-soft" : ""}
            onClick={() => navigate("secureNote")}
          >
            <span class="nav-symbol"><NavIcon name="folder" /></span>
            {t("全部笔记")}
          </button>
          {categories.map((name) => (
            <button
              class={category === name ? "selected-soft" : ""}
              onClick={() => {
                navigate("secureNote");
                setCategory(name);
              }}
            >
              <span class="nav-symbol"><NavIcon name="folder" /></span>
              {name}
            </button>
          ))}
        </nav>
        <div class="sidebar-caption">{t("工具")}</div>
        <nav>
          {[
            ["backup", t("备份与导入"), "backup"],
            ["generate", t("密码生成器"), "wand"],
            ["audit", t("密码健康"), "shield"],
            ["trash", t("回收站"), "trash"],
          ].map(([key, label, icon]) => (
            <button
              class={section === key ? "selected-soft" : ""}
              onClick={() => navigate(key)}
            >
              <span class="nav-symbol"><NavIcon name={icon} /></span>
              {label}
            </button>
          ))}
        </nav>
        <div class="sidebar-bottom">
          <button onClick={() => navigate("settings")}><span class="nav-symbol"><NavIcon name="gear" /></span>{t("设置")}</button>
          <button
            onClick={() =>
              run(async () => {
                await lockWithDraft();
              })
            }
          >
            <span class="nav-symbol"><NavIcon name="lock" /></span>
            {t("锁定资料库")}
          </button>
        </div>
      </aside>
      {["backup", "generate", "audit", "settings"].includes(section) ? (
        <section class="tools-panel">
          <Tools
            section={section}
            openItem={(id: string) => {
              const found = doc.items.find((i: Item) => i.id === id);
              if (found) {
                navigate(found.type);
                setSelected(id);
              }
            }}
            doc={doc}
            refresh={refresh}
            run={run}
            setToast={setToast}
            copy={copy}
          />
        </section>
      ) : (
        <>
          <section class="record-list">
            <header>
              <h2>
                {category ||
                  t(sections.find((s) => s[0] === section)?.[1] || "") ||
                  t("回收站")}
              </h2>
              <button
                class="icon-button"
                title={t("新建")}
                disabled={section === "trash"}
                onClick={newItem}
              >
                ＋
              </button>
            </header>
            <label class="search">
              <span><NavIcon name="search" /></span>
              <input
                data-vault-search="true"
                aria-label={t("搜索资料")}
                placeholder={t("搜索")}
                value={search}
                onInput={(e) => setSearch(e.currentTarget.value)}
              />
              <kbd>⌘ K</kbd>
            </label>
            <div class="list-caption">
              {visible.length} {t("条资料")}
            </div>
            <div class="records">
              {visible.map((record) => (
                <button
                  class={"record " + (record.type === "secureNote" ? "" : "with-tile ") + (item?.id === record.id ? "active" : "")}
                  onClick={() => leaveEditor(() => {
                    setSelected(record.id);
                    setEditing(undefined);
                  })}
                >
                  {record.type !== "secureNote" && (
                    <span class={`tile tone-${tileFor(record.title).tone}`} aria-hidden="true">{tileFor(record.title).initial}</span>
                  )}
                  <span class="record-body">
                  <strong>
                    {record.title || t("未命名")}
                    {record.isFavorite && <span class="favorite">★</span>}
                  </strong>
                  <small>
                    {record.type === "secureNote"
                      ? ((record.note ?? "")
                          .split("\n")
                          .find((s: string) => s.trim()) ?? t("空白笔记"))
                      : record.username || record.network || t("暂无备注")}
                  </small>
                  <time>
                    {record.updatedAt
                      ? new Date(record.updatedAt).toLocaleDateString(dateLocale(), {
                          month: "short",
                          day: "numeric",
                        })
                      : ""}
                  </time>
                  </span>
                </button>
              ))}
            </div>
          </section>
          <section class="detail">
            {editing ? (
              <Editor
                item={editing}
                onCancel={() => {
                  void run(async () => {
                    await flushDraft();
                    setEditing(undefined);
                    await refresh();
                  });
                }}
                onDraft={changedDraft}
                draftStatus={draftStatus}
                onSave={(value) => run(() => save(value, true))}
                busy={busy || !canEditItem(editing)}
              />
            ) : item ? (
              <>
                <header class="detail-toolbar">
                  <span class="muted">
                    {item.category || t("全部资料")} /{" "}
                    {item.type === "secureNote" ? t("笔记") : t("条目")}
                  </span>
                  <div class="actions">
                    <button onClick={() => setHistory(item.id)}>
                      {t("版本历史")}
                    </button>
                    <button
                      disabled={!canEditItem(item)}
                      title={t("收藏")}
                      aria-pressed={!!item.isFavorite}
                      onClick={() =>
                        run(() =>
                          save({ ...item, isFavorite: !item.isFavorite }),
                        )
                      }
                    >
                      {item.isFavorite ? "★" : "☆"}
                    </button>
                    <button
                      disabled={!canEditItem(item)}
                      onClick={() => {
                        if (
                          (pendingDraft.current ?? recoveredDraft)?.id &&
                          (pendingDraft.current ?? recoveredDraft)?.id !==
                            item.id
                        ) {
                          setError(t("请先保存或丢弃现有草稿"));
                          return;
                        }
                        const current = pendingDraft.current ?? recoveredDraft;
                        const resume = current?.id === item.id ? current : undefined;
                        const next = { ...(resume ?? item) };
                        setEditing(next);
                      }}
                    >
                      {t("编辑")}
                    </button>
                    <button
                      disabled={!canEditItem(item)}
                      onClick={() =>
                        run(() =>
                          save({
                            ...item,
                            isDeleted: !item.isDeleted,
                            deletedAt: item.isDeleted
                              ? ""
                              : new Date().toISOString(),
                          }),
                        )
                      }
                    >
                      {item.isDeleted ? t("恢复") : t("移到回收站")}
                    </button>
                  </div>
                </header>
                <article class="note-body">
                  <div class="eyebrow">
                    {item.isFavorite ? t("已收藏 · ") : ""}
                    {t("已保存")}
                  </div>
                  <h1>{item.title}</h1>
                  <p class="metadata">
                    {item.updatedAt
                      ? new Date(item.updatedAt).toLocaleString(dateLocale())
                      : ""}
                  </p>
                  {item.type === "password" && (
                    <>
                      <Field
                        label={t("账号")}
                        value={item.username}
                        onCopy={copy}
                      />
                      <Field
                        label={t("密码")}
                        value={item.password}
                        secret
                        onCopy={copy}
                      />
                      <Field label={t("网站")} value={item.url} onCopy={copy} />
                      {(item.accounts ?? []).map((a: any) => (
                        <div class="subaccount">
                          <Field
                            label={a.label || t("其他账号")}
                            value={a.username}
                            onCopy={copy}
                          />
                          <Field
                            label={t("密码")}
                            value={a.password}
                            secret
                            onCopy={copy}
                          />
                        </div>
                      ))}
                      {(item.passwordHistory ?? []).length > 0 && (
                        <details>
                          <summary>{t("密码历史")}</summary>
                          {item.passwordHistory.map((h: any) => (
                            <Field
                              label={
                                h.changedAt ?? h.timestamp ?? t("历史密码")
                              }
                              value={h.password ?? ""}
                              secret
                              onCopy={copy}
                            />
                          ))}
                        </details>
                      )}
                    </>
                  )}
                  {item.type === "totp" && <Code item={item} onCopy={copy} />}{" "}
                  {item.type === "crypto" && (
                    <>
                      {["address", "privateKey", "mnemonic"].map((k, i) => (
                        <Field
                          label={[t("地址"), t("私钥"), t("助记词")][i]}
                          value={item[k]}
                          secret={i > 0}
                          onCopy={copy}
                        />
                      ))}
                    </>
                  )}
                  <PasskeyDetails key={item.id} item={item} refresh={refresh} editable={canEditItem(item)} />
                  {(item.type === "creditCard" || item.type === "identity") &&
                    Object.entries(
                      item[item.type === "creditCard" ? "card" : "identity"] ??
                        {},
                    ).map(([name, value]) => (
                      <Field
                        key={name}
                        label={structuredLabel(name)}
                        value={String(value ?? "")}
                        secret={["number", "securityCode"].includes(name)}
                        onCopy={copy}
                      />
                    ))}
                  {(item.customFields ?? []).map((field: any) => (
                    <Field
                      key={field.id}
                      label={[field.group, field.label]
                        .filter(Boolean)
                        .join(" / ")}
                      value={field.value}
                      secret={field.kind === "concealed"}
                      onCopy={copy}
                    />
                  ))}
                  {item.noteFormat === "rich-v1" ? (
                    <RichNoteEditor key={item.id} item={item} />
                  ) : (
                    <Markdown text={item.note ?? ""} />
                  )}
                  {(item.tags ?? []).length > 0 && (
                    <div class="tags">
                      {item.tags.map((tag: string) => (
                        <span>#{tag}</span>
                      ))}
                    </div>
                  )}
                </article>
                <footer class="detail-status">
                  <span>{t("已保存到本地")}</span>
                  <span>{fmt(t("{count} 字"), { count: [...(item.note ?? "")].length })}</span>
                </footer>
              </>
            ) : (
              <div class="empty-view">
                <span class="lock-symbol">▤</span>
                <h2>{t("为重要信息留一个位置")}</h2>
                <p>{t("新建笔记，或从备份导入已有资料。")}</p>
                {section !== "trash" && (
                  <button class="primary" onClick={newItem}>
                    {t("新建")}
                    {t(sections.find((s) => s[0] === section)?.[1] || "")}
                  </button>
                )}
              </div>
            )}
          </section>
        </>
      )}
      {error && (
        <div class="error-banner" role="alert">
          {error}
          <button onClick={() => setError("")}>{t("关闭")}</button>
        </div>
      )}
      {doc && state?.unlocked && history && (
        <HistoryDialog
          id={history}
          close={() => setHistory(undefined)}
          refresh={refresh}
        />
      )}
      {toast && (
        <div class="toast" role="status">
          {toast}
        </div>
      )}
    </main>
  );
}

render(<App />, document.getElementById("app")!);
