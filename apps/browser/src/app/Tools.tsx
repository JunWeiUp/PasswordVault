import { useEffect, useState } from "preact/hooks";
import { ImportReviewPanel, SecurityCenterPanel } from "../Capabilities";
import { RecoveryPanel } from "../RecoveryPanel";
import { WebDAVPanel } from "../WebDAVPanel";
import { command, isExtension, message } from "../client";
import { setLocale, setTheme, t, useLocale } from "../i18n";
import { Field } from "./components";

export function Tools({ section, doc, refresh, run, setToast, copy, openItem }: any) {
  useLocale();
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
            backup: t("备份与恢复"),
            generate: t("密码生成器"),
            audit: t("安全检查"),
            settings: t("设置"),
          }[section as string]
        }
      </h1>
      {section === "backup" ? (
        <>
          <section class="panel"><WebDAVPanel settings={doc.settings} onComplete={refresh} /></section>
          <section class="panel"><ImportReviewPanel onComplete={refresh} /></section>
          <RecoveryPanel onComplete={refresh} copy={copy} />
          <section class="panel">
          <h2>{t("加密备份")}</h2>
          <p class="muted">
            {t(
              "将资料保存为加密备份，或导入旧版 PasswordVault / 常见密码管理器的导出文件。",
            )}
          </p>
          <label>
            {t("备份密码")}
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
            {t("导出加密备份")}
          </button>
          </section>
          <section class="panel">
          <h2>{t("导入资料")}</h2>
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
                setToast(
                  t("已导入 {count} 条资料").replace(
                    "{count}",
                    String(r.imported),
                  ),
                );
                setBackupPassword("");
              })
            }
          >
            {t("导入所选文件")}
          </button>
          </section>
          <details class="panel">
            <summary>{t("其他导出方式")}</summary>
            <label class="checkbox">
              <input
                type="checkbox"
                checked={plain}
                onChange={(e) => setPlain(e.currentTarget.checked)}
              />
              {t("我知道明文文件包含完整密码和笔记")}
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
              {t("导出明文 JSON")}
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
              {t("导出明文 CSV")}
            </button>
          </details>
        </>
      ) : section === "generate" ? (
        <>
          <p class="muted">{t("为每个账号生成不同的密码。")}</p>
          <label>
            {t("长度：")}
            {length}
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
            {t("生成密码")}
          </button>
          {generated && (
            <Field
              label={t("生成结果")}
              value={generated}
              onCopy={async (v) => {
                await navigator.clipboard.writeText(v);
                setToast(t("已复制"));
              }}
            />
          )}
        </>
      ) : section === "audit" ? (
        <SecurityCenterPanel items={doc.items} openItem={openItem} />
      ) : (
        <>
          <p class="muted">
            {t("此资料库保存在当前浏览器中，请定期导出加密备份。")}
          </p>
          <div class="seg-group">
            <span class="seg-label">{t("界面语言")}</span>
            <div class="seg-bar" role="radiogroup" aria-label={t("界面语言")}>
              {([["zh", "中文"], ["en", "English"]] as const).map(([val, label]) => {
                const active = (doc.settings.language ?? "zh") === val;
                return (
                  <button
                    type="button"
                    role="radio"
                    aria-checked={active}
                    class={active ? "on" : ""}
                    onClick={() => {
                      void run(async () => {
                        await command({ op: "settings", settings: { language: val } });
                        setLocale(val);
                        await refresh();
                      });
                    }}
                  >
                    {label}
                  </button>
                );
              })}
            </div>
          </div>
          <div class="seg-group">
            <span class="seg-label">{t("外观")}</span>
            <div class="seg-bar" role="radiogroup" aria-label={t("外观")}>
              {([["system", t("跟随系统")], ["light", t("浅色")], ["dark", t("深色")]] as const).map(([val, label]) => {
                const active = (doc.settings.theme ?? "system") === val;
                return (
                  <button
                    type="button"
                    role="radio"
                    aria-checked={active}
                    class={active ? "on" : ""}
                    onClick={() => {
                      void run(async () => {
                        await command({ op: "settings", settings: { theme: val } });
                        setTheme(val);
                        await refresh();
                      });
                    }}
                  >
                    {label}
                  </button>
                );
              })}
            </div>
          </div>
          <div class="seg-group">
            <span class="seg-label">{t("自动锁定")}</span>
            <div class="seg-bar" role="radiogroup" aria-label={t("自动锁定")}>
              {[1, 2, 5, 10, 15, 30, 60].map((m) => {
                const active = (doc.settings.autoLockMinutes ?? 60) === m;
                const label = m === 60 ? t("1 小时") : t("{count} 分钟").replace("{count}", String(m));
                return (
                  <button
                    type="button"
                    role="radio"
                    aria-checked={active}
                    class={active ? "on" : ""}
                    onClick={() =>
                      void run(async () => {
                        await command({ op: "settings", settings: { autoLockMinutes: m } });
                        await refresh();
                      })
                    }
                  >
                    {label}
                  </button>
                );
              })}
            </div>
          </div>
          <small>
            {t("浏览器回收后台进程或系统空闲时，扩展也会自动锁定。")}
          </small>
          <hr />
          <h2>{t("更改主密码")}</h2>
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
                setToast(t("主密码已更新"));
              });
            }}
          >
            <label>
              {t("当前密码")}
              <input
                required
                type="password"
                autoComplete="current-password"
                value={current}
                onInput={(e) => setCurrent(e.currentTarget.value)}
              />
            </label>
            <label>
              {t("新密码")}
              <input
                required
                minLength={10}
                type="password"
                autoComplete="new-password"
                value={replacement}
                onInput={(e) => setReplacement(e.currentTarget.value)}
              />
            </label>
            <button class="primary">{t("更新主密码")}</button>
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
                {t("改为连接 Mac")}
              </button>
            </>
          )}
        </>
      )}
    </div>
  );
}
