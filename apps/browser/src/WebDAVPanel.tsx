import { t, useLocale } from "./i18n";
import { useEffect, useRef, useState } from "preact/hooks";
import { command } from "./client";
import { WebDAVClient, type DAVConfig, type RemoteBackup } from "./webdav";
export function WebDAVPanel({
  settings,
  onComplete,
}: {
  settings: any;
  onComplete: () => Promise<void>;
}) {
  useLocale();
  const [config, setConfig] = useState<DAVConfig>({
    url: "",
    username: "",
    password: "",
    folder: "PasswordVault",
    ...settings.webdav,
  });
  const [password, setPassword] = useState("");
  const [files, setFiles] = useState<RemoteBackup[]>([]);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const active = useRef(true);
  const abort = useRef<AbortController>();
  useEffect(
    () => () => {
      active.current = false;
      abort.current?.abort();
    },
    [],
  );
  async function run(action: (client: WebDAVClient) => Promise<string>) {
    if (busy) return;
    setBusy(true);
    setMessage("");
    const controller = new AbortController();
    abort.current = controller;
    const timeout = setTimeout(() => controller.abort(), 90000);
    try {
      const result = await action(new WebDAVClient(config, controller.signal));
      if (active.current) setMessage(result);
    } catch {
      if (active.current)
        setMessage(
          t("操作未完成，原有资料保留。请检查地址、认证和服务器 CORS 配置。"),
        );
    } finally {
      clearTimeout(timeout);
      if (active.current) setBusy(false);
    }
  }
  return (
    <section>
      <h2>{t("WebDAV 备份")}</h2>
      <p>
        {t(
          "上传完整加密备份。服务器需允许此页面来源的 CORS，以及 PROPFIND、MKCOL、PUT、GET 和 Authorization 请求头。",
        )}
      </p>
      <fieldset disabled={busy}>
        {(["url", "username", "password", "folder"] as const).map(
          (key, index) => (
            <label>
              {
                [
                  t("HTTPS 服务地址"),
                  t("用户名"),
                  t("服务器密码"),
                  t("文件夹"),
                ][index]
              }
              <input
                autoComplete="off"
                type={key === "password" ? "password" : "text"}
                value={config[key]}
                onInput={(e) =>
                  setConfig({ ...config, [key]: e.currentTarget.value })
                }
              />
            </label>
          ),
        )}
        <button
          onClick={() =>
            run(async () => {
              await command({ op: "settings", settings: { webdav: config } });
              await onComplete();
              return t("配置已加密保存");
            })
          }
        >
          {t("保存配置")}
        </button>
        <button
          onClick={() =>
            run(async (client) => {
              const result = await client.list();
              if (active.current) setFiles(result);
              return t("{count} 份备份").replace(
                "{count}",
                String(result.length),
              );
            })
          }
        >
          {t("连接并刷新")}
        </button>
        <label>
          {t("备份文件密码")}
          <input
            type="password"
            autoComplete="new-password"
            value={password}
            onInput={(e) => setPassword(e.currentTarget.value)}
          />
        </label>
        <button
          disabled={!password}
          onClick={() =>
            run(async (client) => {
              const { content } = await command({ op: "export", password });
              if (!active.current) throw Error("Closed");
              await client.request("MKCOL");
              const name = `PasswordVault-${new Date().toISOString().replace(/[:.]/g, "-")}-${crypto.randomUUID().slice(0, 8)}.pvault`;
              await client.request(
                "PUT",
                new URL(name, client.base).href,
                content,
              );
              if (active.current) setFiles(await client.list());
              return t("加密备份已上传");
            })
          }
        >
          {t("上传加密备份")}
        </button>
        {files.map((file) => (
          <article key={file.url}>
            <strong>{file.name}</strong>
            <p>
              {file.modified || t("修改时间未知")} ·{" "}
              {file.size === undefined ? t("大小未知") : `${file.size} bytes`}
            </p>
            <button
              disabled={!password}
              onClick={() => {
                if (
                  !confirm(
                    t(
                      "合并恢复 {name}？当前独有条目保留；同 ID 采用较新版本。",
                    ).replace("{name}", file.name),
                  )
                )
                  return;
                void run(async (client) => {
                  const content = await client.request("GET", file.url);
                  if (!active.current) throw Error("Closed");
                  await command({ op: "import", content, password });
                  await onComplete();
                  return t("已合并恢复");
                });
              }}
            >
              {t("合并恢复")}
            </button>
          </article>
        ))}
      </fieldset>
      {message && <p role="status">{message}</p>}
    </section>
  );
}
