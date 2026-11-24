import { useEffect, useState } from "preact/hooks";
import { command } from "../client";
import { t, useLocale } from "../i18n";

export type Item = { id: string; type: string; title: string; [key: string]: any };

export function NavIcon({ name }: { name: string }) {
  const paths: Record<string, string> = {
    note: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M8 13h8M8 17h5",
    key: "M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.78 7.78 5.5 5.5 0 0 1 7.78-7.78zm0 0L15.5 7.5m0 0 3 3L22 7l-3-3m-3.5 3.5L19 4",
    clock: "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zm0-14v4l3 2",
    wallet: "M3 7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7zm12 5h4",
    card: "M2 7a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7zm0 3h20",
    user: "M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z",
    folder: "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z",
    backup: "M12 3v12m0 0-4-4m4 4 4-4M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2",
    wand: "M15 4V2m0 14v-2M8 9h2m10 0h2m-4.2-4.2L19 3.6M11 11 4 18l2 2 7-7",
    shield: "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z",
    trash: "M3 6h18M8 6V4h8v2m-9 0 1 14h8l1-14",
    gear: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm7.4-2.4a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9c.26.6.85 1 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z",
    lock: "M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2zm3 0V7a4 4 0 0 1 8 0v4",
    search: "M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zm10 2-4.35-4.35",
  };
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d={paths[name] ?? paths.note} />
    </svg>
  );
}

export function Markdown({ text }: { text: string }) {
  useLocale();
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

export function Field({
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
  useLocale();
  const [shown, setShown] = useState(false);
  return (
    <div class="field-row">
      <div>
        <small>{t(label)}</small>
        <p class={secret ? "mono" : ""}>
          {secret && !shown ? "••••••••••••" : value || t("未填写")}
        </p>
      </div>
      <div class="actions">
        {secret && (
          <button onClick={() => setShown(!shown)}>
            {shown ? t("隐藏") : t("显示")}
          </button>
        )}
        <button disabled={!value} onClick={() => onCopy(value)}>
          {t("复制")}
        </button>
      </div>
    </div>
  );
}

export function Code({
  item,
  onCopy,
}: {
  item: Item;
  onCopy: (value: string) => Promise<void>;
}) {
  useLocale();
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
      <span>
        {seconds} {t("秒后刷新")}
      </span>
      <button onClick={() => onCopy(code)}>{t("复制验证码")}</button>
    </div>
  );
}
