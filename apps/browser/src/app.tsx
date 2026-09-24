import { render } from "preact";
import { useEffect, useState, useRef } from "preact/hooks";
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
import "./style.css";
type Item = { id: string; type: string; title: string; [key: string]: any };
const sections = [
  ["secureNote", "笔记", "▤"],
  ["password", "密码", "⌘"],
  ["totp", "验证码", "◷"],
  ["crypto", "钱包", "▱"],
];
function Markdown({ text }: { text: string }) {
  return (
    <div class="markdown">
      {text.split("\n").map((line, i) =>
        line.startsWith("### ") ? (
          <h3 key={i}>{line.slice(4)}</h3>
        ) : line.startsWith("## ") ? (
          <h2 key={i}>{line.slice(3)}</h2>
        ) : line.startsWith("# ") ? (
          <h1 key={i}>{line.slice(2)}</h1>
        ) : line.startsWith("- ") ? (
          <p key={i} class="bullet">
            • {line.slice(2)}
          </p>
        ) : (
          <p key={i}>{line || "\u00a0"}</p>
        ),
      )}
    </div>
  );
}
function App() {
  const [state, setState] = useState<any>();
  const [doc, setDoc] = useState<any>();
  const [section, setSection] = useState("secureNote");
  const [category, setCategory] = useState("");
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState("");
  const [editing, setEditing] = useState<Item>();
  const actionBusy = useRef(false);
  const polling = useRef(false);
  const generation = useRef(0);
  async function refresh() {
    const s = await status();
    setState(s);
    if (s.unlocked && s.mode === "independent") {
      const data = await command({ op: "list" });
      setDoc(data);
    } else {
      setDoc(undefined);
      setEditing(undefined);
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
      setError(errorText(e));
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
            setEditing(undefined);
          }
        })
        .catch((e) => {
          if (version === generation.current) setError(errorText(e));
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
  async function save(value: Item) {
    await command({
      op: "save",
      item: { ...value, updatedAt: new Date().toISOString() },
    });
    setSelected(value.id);
    await refresh();
    setEditing(undefined);
    setToast("已保存");
  }
  function navigate(next: string) {
    setSection(next);
    setCategory("");
    setSearch("");
    setEditing(undefined);
  }
  function newItem() {
    setEditing({
      id: crypto.randomUUID(),
      type: section,
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
      setToast("已复制");
    });
  }
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || !doc) return;
      if (event.key.toLowerCase() === "k") {
        event.preventDefault();
        document
          .querySelector<HTMLInputElement>('input[aria-label="搜索资料"]')
          ?.focus();
      } else if (event.key.toLowerCase() === "l") {
        event.preventDefault();
        void run(async () => {
          await lock();
          setDoc(undefined);
          setEditing(undefined);
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
              重新尝试
            </button>
          </>
        ) : (
          <p class="muted">正在打开资料库…</p>
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
            使用独立浏览器资料库
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
              setError("两次输入的主密码不一致。");
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
          <h1>{state.exists ? "欢迎回来" : "留下重要的资料"}</h1>
          <p>
            {state.exists
              ? "解锁后继续整理你的笔记和账号。"
              : "创建加密资料库。主密码无法找回，请妥善保管。"}
          </p>
          <label>
            主密码
            <input
              autoFocus
              required
              minLength={state.exists ? 1 : 10}
              type="password"
              autoComplete={state.exists ? "current-password" : "new-password"}
              placeholder="至少 10 个字符"
              value={password}
              onInput={(e) => setPassword(e.currentTarget.value)}
            />
          </label>
          {!state.exists && (
            <label>
              再次输入
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
            {busy ? "正在解锁…" : state.exists ? "解锁资料库" : "创建资料库"}
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
              连接 Mac 资料库
            </button>
          )}
          {error && (
            <p class="error" role="alert">
              {error}
            </p>
          )}
          <small>本地保存 · 自动锁定</small>
        </form>
      </div>
    );
  return (
    <main class="workspace">
      <aside class="sidebar">
        {brand}
        <div class="sidebar-caption">资料库</div>
        <nav>
          {sections.map(([key, label, icon]) => (
            <button
              class={section === key ? "selected" : ""}
              onClick={() => navigate(key)}
            >
              <span class="nav-symbol">{icon}</span>
              {label}
              <span class="count">
                {items.filter((i) => i.type === key && !i.isDeleted).length}
              </span>
            </button>
          ))}
        </nav>
        <div class="sidebar-caption">笔记分类</div>
        <nav>
          <button
            class={section === "secureNote" && !category ? "selected-soft" : ""}
            onClick={() => navigate("secureNote")}
          >
            ▱　全部笔记
          </button>
          {categories.map((name) => (
            <button
              class={category === name ? "selected-soft" : ""}
              onClick={() => {
                navigate("secureNote");
                setCategory(name);
              }}
            >
              ▱　{name}
            </button>
          ))}
        </nav>
        <div class="sidebar-caption">工具</div>
        <nav>
          {[
            ["backup", "备份与恢复", "↧"],
            ["generate", "密码生成器", "⚙"],
            ["audit", "安全检查", "◉"],
            ["trash", "最近删除", "♲"],
          ].map(([key, label, icon]) => (
            <button
              class={section === key ? "selected-soft" : ""}
              onClick={() => navigate(key)}
            >
              <span class="nav-symbol">{icon}</span>
              {label}
            </button>
          ))}
        </nav>
        <div class="sidebar-bottom">
          <button onClick={() => navigate("settings")}>⚙　设置</button>
          <button
            onClick={() =>
              run(async () => {
                await lock();
                setDoc(undefined);
                setEditing(undefined);
              })
            }
          >
            ⌑　锁定资料库
          </button>
        </div>
      </aside>
      {["backup", "generate", "audit", "settings"].includes(section) ? (
        <section class="tools-panel">
          <Tools
            section={section}
            doc={doc}
            refresh={refresh}
            run={run}
            setToast={setToast}
          />
        </section>
      ) : (
        <>
          <section class="record-list">
            <header>
              <h2>
                {category ||
                  sections.find((s) => s[0] === section)?.[1] ||
                  "最近删除"}
              </h2>
              <button
                class="icon-button"
                title="新建"
                disabled={section === "trash"}
                onClick={newItem}
              >
                ＋
              </button>
            </header>
            <label class="search">
              <span>⌕</span>
              <input
                aria-label="搜索资料"
                placeholder="搜索"
                value={search}
                onInput={(e) => setSearch(e.currentTarget.value)}
              />
              <kbd>⌘ K</kbd>
            </label>
            <div class="list-caption">{visible.length} 条资料</div>
            <div class="records">
              {visible.map((record) => (
                <button
                  class={"record " + (item?.id === record.id ? "active" : "")}
                  onClick={() => {
                    setSelected(record.id);
                    setEditing(undefined);
                  }}
                >
                  <strong>
                    {record.title || "未命名"}
                    {record.isFavorite && <span class="favorite">★</span>}
                  </strong>
                  <small>
                    {record.type === "secureNote"
                      ? ((record.note ?? "")
                          .split("\n")
                          .find((s: string) => s.trim()) ?? "空白笔记")
                      : record.username || record.network || "暂无备注"}
                  </small>
                  <time>
                    {record.updatedAt
                      ? new Date(record.updatedAt).toLocaleDateString("zh-CN", {
                          month: "short",
                          day: "numeric",
                        })
                      : ""}
                  </time>
                </button>
              ))}
            </div>
          </section>
          <section class="detail">
            {editing ? (
              <Editor
                item={editing}
                onCancel={() => setEditing(undefined)}
                onSave={(value) => run(() => save(value))}
                busy={busy}
              />
            ) : item ? (
              <>
                <header class="detail-toolbar">
                  <span class="muted">
                    {item.category || "全部资料"} /{" "}
                    {item.type === "secureNote" ? "笔记" : "条目"}
                  </span>
                  <div class="actions">
                    <button
                      title="收藏"
                      aria-pressed={!!item.isFavorite}
                      onClick={() =>
                        run(() =>
                          save({ ...item, isFavorite: !item.isFavorite }),
                        )
                      }
                    >
                      {item.isFavorite ? "★" : "☆"}
                    </button>
                    <button onClick={() => setEditing({ ...item })}>
                      编辑
                    </button>
                    <button
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
                      {item.isDeleted ? "恢复" : "移至最近删除"}
                    </button>
                  </div>
                </header>
                <article class="note-body">
                  <div class="eyebrow">
                    {item.isFavorite ? "已收藏 · " : ""}已保存
                  </div>
                  <h1>{item.title}</h1>
                  <p class="metadata">
                    {item.updatedAt
                      ? new Date(item.updatedAt).toLocaleString("zh-CN")
                      : ""}
                  </p>
                  {item.type === "password" && (
                    <>
                      <Field label="账号" value={item.username} onCopy={copy} />
                      <Field
                        label="密码"
                        value={item.password}
                        secret
                        onCopy={copy}
                      />
                      <Field label="网站" value={item.url} onCopy={copy} />
                      {(item.accounts ?? []).map((a: any) => (
                        <div class="subaccount">
                          <Field
                            label={a.label || "其他账号"}
                            value={a.username}
                            onCopy={copy}
                          />
                          <Field
                            label="密码"
                            value={a.password}
                            secret
                            onCopy={copy}
                          />
                        </div>
                      ))}
                      {(item.passwordHistory ?? []).length > 0 && (
                        <details>
                          <summary>密码历史</summary>
                          {item.passwordHistory.map((h: any) => (
                            <Field
                              label={h.changedAt ?? h.timestamp ?? "历史密码"}
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
                          label={["地址", "私钥", "助记词"][i]}
                          value={item[k]}
                          secret={i > 0}
                          onCopy={copy}
                        />
                      ))}
                    </>
                  )}
                  <Markdown text={item.note ?? ""} />
                  {(item.tags ?? []).length > 0 && (
                    <div class="tags">
                      {item.tags.map((tag: string) => (
                        <span>#{tag}</span>
                      ))}
                    </div>
                  )}
                </article>
                <footer class="detail-status">
                  <span>已保存到本地</span>
                  <span>{(item.note ?? "").length} 字</span>
                </footer>
              </>
            ) : (
              <div class="empty-view">
                <span class="lock-symbol">▤</span>
                <h2>为重要信息留一个位置</h2>
                <p>新建笔记，或从备份导入已有资料。</p>
                {section !== "trash" && (
                  <button class="primary" onClick={newItem}>
                    新建{sections.find((s) => s[0] === section)?.[1]}
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
          <button onClick={() => setError("")}>关闭</button>
        </div>
      )}
      {toast && (
        <div class="toast" role="status">
          {toast}
        </div>
      )}
    </main>
  );
}
function Field({
  label,
  value = "",
  secret = false,
  onCopy,
}: {
  label: string;
  value?: string;
  secret?: boolean;
  onCopy: (value: string) => Promise<void>;
}) {
  const [shown, setShown] = useState(false);
  return (
    <div class="field-row">
      <div>
        <small>{label}</small>
        <p class={secret ? "mono" : ""}>
          {secret && !shown ? "••••••••••••" : value || "未填写"}
        </p>
      </div>
      <div class="actions">
        {secret && (
          <button onClick={() => setShown(!shown)}>
            {shown ? "隐藏" : "显示"}
          </button>
        )}
        <button disabled={!value} onClick={() => onCopy(value)}>
          复制
        </button>
      </div>
    </div>
  );
}
function Code({
  item,
  onCopy,
}: {
  item: Item;
  onCopy: (value: string) => Promise<void>;
}) {
  const [code, setCode] = useState("");
  const [seconds, setSeconds] = useState(0);
  useEffect(() => {
    const update = () => {
      const time = Math.floor(Date.now() / 1000);
      setSeconds((item.period ?? 30) - (time % (item.period ?? 30)));
      void command({
        op: "totp",
        secret: item.secret,
        period: item.period ?? 30,
        time,
      })
        .then((v) => setCode(v.code))
        .catch(() => setCode(""));
    };
    update();
    const timer = setInterval(update, 1000);
    return () => clearInterval(timer);
  }, [item.id, item.secret]);
  return (
    <div class="totp">
      <strong>
        {code.slice(0, 3)} {code.slice(3)}
      </strong>
      <span>{seconds} 秒后刷新</span>
      <button onClick={() => onCopy(code)}>复制验证码</button>
    </div>
  );
}
function Editor({
  item,
  onCancel,
  onSave,
  busy,
}: {
  item: Item;
  onCancel: () => void;
  onSave: (item: Item) => void;
  busy: boolean;
}) {
  const [draft, setDraft] = useState<Item>(item);
  const [preview, setPreview] = useState(false);
  const update = (key: string, value: any) =>
    setDraft({ ...draft, [key]: value });
  function field(key: string, label: string, secret = false) {
    return (
      <label>
        {label}
        <input
          type={secret ? "password" : "text"}
          value={draft[key] ?? ""}
          onInput={(e) => update(key, e.currentTarget.value)}
          autoComplete="off"
        />
      </label>
    );
  }
  return (
    <form
      class="editor"
      onSubmit={(e) => {
        e.preventDefault();
        const next = { ...draft };
        if (
          item.type === "password" &&
          item.password &&
          item.password !== draft.password
        )
          next.passwordHistory = [
            ...(item.passwordHistory ?? []),
            { password: item.password, changedAt: new Date().toISOString() },
          ];
        onSave(next);
      }}
    >
      <header class="detail-toolbar">
        <span>{item.title ? "编辑资料" : "新建资料"}</span>
        <div class="actions">
          <button type="button" onClick={onCancel}>
            取消
          </button>
          <button class="primary" disabled={busy}>
            保存
          </button>
        </div>
      </header>
      <div class="editor-fields">
        <input
          class="title-input"
          aria-label="标题"
          required
          placeholder="标题"
          value={draft.title}
          onInput={(e) => update("title", e.currentTarget.value)}
        />
        {item.type === "password" && (
          <>
            {field("username", "账号")}
            {field("password", "密码", true)}
            {field("url", "网站")}
          </>
        )}
        {item.type === "totp" && (
          <>
            {field("username", "账号")}
            {field("secret", "密钥", true)}
            <label>
              刷新间隔（秒）
              <input
                type="number"
                min="1"
                max="86400"
                value={draft.period ?? 30}
                onInput={(e) => update("period", Number(e.currentTarget.value))}
              />
            </label>
          </>
        )}
        {item.type === "crypto" && (
          <>
            {field("network", "网络")}
            {field("address", "地址")}
            {field("privateKey", "私钥", true)}
            {field("mnemonic", "助记词", true)}
          </>
        )}
        {field("category", "分类")}
        <label>
          标签（逗号分隔）
          <input
            value={(draft.tags ?? []).join(", ")}
            onInput={(e) =>
              update(
                "tags",
                e.currentTarget.value
                  .split(/[,，]/)
                  .map((v) => v.trim())
                  .filter(Boolean),
              )
            }
          />
        </label>
        <div class="editor-options">
          <span>Markdown</span>
          <button
            type="button"
            aria-pressed={preview}
            onClick={() => setPreview(!preview)}
          >
            {preview ? "编辑" : "预览"}
          </button>
          <label>
            <input
              type="checkbox"
              checked={!!draft.isPinned}
              onChange={(e) => update("isPinned", e.currentTarget.checked)}
            />
            置顶
          </label>
        </div>
        {preview ? (
          <Markdown text={draft.note ?? ""} />
        ) : (
          <textarea
            class="note-editor"
            aria-label="笔记正文"
            placeholder="开始写下重要的事…"
            value={draft.note ?? ""}
            onInput={(e) => update("note", e.currentTarget.value)}
          />
        )}
      </div>
    </form>
  );
}
function Tools({ section, doc, refresh, run, setToast }: any) {
  const [backupPassword, setBackupPassword] = useState("");
  const [file, setFile] = useState<File>();
  const [plain, setPlain] = useState(false);
  const [generated, setGenerated] = useState("");
  const [length, setLength] = useState(20);
  const [audit, setAudit] = useState<any[]>([]);
  const [current, setCurrent] = useState("");
  const [replacement, setReplacement] = useState("");
  useEffect(() => {
    setGenerated("");
    setAudit([]);
    if (section === "audit")
      void run(async () => setAudit(await command({ op: "audit" })));
  }, [section]);
  function download(content: string, name: string) {
    const url = URL.createObjectURL(
      new Blob([content], { type: "application/octet-stream" }),
    );
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  return (
    <div class="tools-content">
      <h1>
        {
          {
            backup: "备份与恢复",
            generate: "密码生成器",
            audit: "安全检查",
            settings: "设置",
          }[section as string]
        }
      </h1>
      {section === "backup" ? (
        <>
          <p class="muted">
            将资料保存为加密备份，或导入旧版 PasswordVault /
            常见密码管理器的导出文件。
          </p>
          <label>
            备份密码
            <input
              type="password"
              autoComplete="new-password"
              value={backupPassword}
              onInput={(e) => setBackupPassword(e.currentTarget.value)}
            />
          </label>
          <button
            class="primary"
            disabled={backupPassword.length < 10}
            onClick={() =>
              run(async () => {
                const r = await command({
                  op: "export",
                  password: backupPassword,
                });
                download(r.content, "PasswordVault.v2.json");
                setBackupPassword("");
              })
            }
          >
            导出加密备份
          </button>
          <hr />
          <h2>导入资料</h2>
          <input
            type="file"
            accept=".json,.csv,.encrypted,.txt"
            onChange={(e) => setFile(e.currentTarget.files?.[0])}
          />
          <button
            disabled={!file}
            onClick={() =>
              run(async () => {
                if (!file || file.size > 64 * 1024 * 1024)
                  throw new Error("invalid");
                const r = await command({
                  op: "import",
                  kind: file.name.endsWith(".csv") ? "csv" : "json",
                  content: await file.text(),
                  password: backupPassword,
                });
                await refresh();
                setToast(`已导入 ${r.imported} 条资料`);
                setBackupPassword("");
              })
            }
          >
            导入所选文件
          </button>
          <hr />
          <details>
            <summary>其他导出方式</summary>
            <label class="checkbox">
              <input
                type="checkbox"
                checked={plain}
                onChange={(e) => setPlain(e.currentTarget.checked)}
              />
              我知道明文文件包含完整密码和笔记
            </label>
            <button
              disabled={!plain}
              onClick={() =>
                run(async () => {
                  const r = await command({ op: "export-plain", kind: "json" });
                  download(r.content, "PasswordVault-plaintext.json");
                  setPlain(false);
                })
              }
            >
              导出明文 JSON
            </button>
            <button
              disabled={!plain}
              onClick={() =>
                run(async () => {
                  const r = await command({ op: "export-plain", kind: "csv" });
                  download(r.content, "PasswordVault-plaintext.csv");
                  setPlain(false);
                })
              }
            >
              导出明文 CSV
            </button>
          </details>
        </>
      ) : section === "generate" ? (
        <>
          <p class="muted">为每个账号生成不同的密码。</p>
          <label>
            长度：{length}
            <input
              type="range"
              min="8"
              max="64"
              value={length}
              onInput={(e) => setLength(Number(e.currentTarget.value))}
            />
          </label>
          <button
            class="primary"
            onClick={() =>
              run(async () =>
                setGenerated(
                  (await command({ op: "generate", length })).password,
                ),
              )
            }
          >
            生成密码
          </button>
          {generated && (
            <Field
              label="生成结果"
              value={generated}
              onCopy={async (v) => {
                await navigator.clipboard.writeText(v);
                setToast("已复制");
              }}
            />
          )}
        </>
      ) : section === "audit" ? (
        <>
          <p class="muted">检查密码长度和重复使用情况。</p>
          {audit.length ? (
            audit.map((entry) => (
              <div class="audit-row">
                <strong>{entry.title}</strong>
                <span>
                  {[entry.weak && "密码较短", entry.reused && "重复使用"]
                    .filter(Boolean)
                    .join(" · ")}
                </span>
              </div>
            ))
          ) : (
            <p>未发现短密码或重复密码。</p>
          )}
        </>
      ) : (
        <>
          <p class="muted">此资料库保存在当前浏览器中，请定期导出加密备份。</p>
          <label>
            自动锁定
            <select
              value={doc.settings.autoLockMinutes ?? 60}
              onChange={(e) =>
                run(async () => {
                  await command({
                    op: "settings",
                    settings: {
                      autoLockMinutes: Number(e.currentTarget.value),
                    },
                  });
                  await refresh();
                })
              }
            >
              {[1, 2, 5, 10, 15, 30, 60].map((m) => (
                <option value={m}>{m === 60 ? "1 小时" : `${m} 分钟`}</option>
              ))}
            </select>
          </label>
          <small>浏览器回收后台进程或系统空闲时，扩展也会自动锁定。</small>
          <hr />
          <h2>更改主密码</h2>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void run(async () => {
                await command({
                  op: "change-password",
                  currentPassword: current,
                  newPassword: replacement,
                });
                setCurrent("");
                setReplacement("");
                setToast("主密码已更新");
              });
            }}
          >
            <label>
              当前密码
              <input
                required
                type="password"
                autoComplete="current-password"
                value={current}
                onInput={(e) => setCurrent(e.currentTarget.value)}
              />
            </label>
            <label>
              新密码
              <input
                required
                minLength={10}
                type="password"
                autoComplete="new-password"
                value={replacement}
                onInput={(e) => setReplacement(e.currentTarget.value)}
              />
            </label>
            <button class="primary">更新主密码</button>
          </form>
          {isExtension && (
            <>
              <hr />
              <button
                onClick={() =>
                  run(async () => {
                    await message({ action: "mode", mode: "native" });
                    await refresh();
                  })
                }
              >
                改为连接 Mac
              </button>
            </>
          )}
        </>
      )}
    </div>
  );
}
render(<App />, document.getElementById("app")!);
