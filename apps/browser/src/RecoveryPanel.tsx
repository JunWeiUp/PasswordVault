import {t,useLocale} from "./i18n";
import { useEffect, useRef, useState } from "preact/hooks";
import { command, recover } from "./client";

export function RecoveryPanel({
  locked = false,
  exists = true,
  onComplete,
  copy,
}: {
  locked?: boolean;
  exists?: boolean;
  onComplete: () => Promise<void>;
  copy: (value: string) => Promise<void>;
}) {
  useLocale();
  const [key, setKey] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [password, setPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [file, setFile] = useState<File>();
  const [enabled, setEnabled] = useState(false);
  const [generated, setGenerated] = useState(false);
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const alive = useRef(true);
  const pending = useRef<AbortController>();
  useEffect(() => {
    if (!locked)
      void command({ op: "recovery-status" })
        .then((value) => {
          if (alive.current) setEnabled(value.enabled);
        })
        .catch(() => {
          if (alive.current) setError(t("无法读取恢复配置。"));
        });
    return () => {
      alive.current = false;
      pending.current?.abort();
    };
  }, []);
  async function run(action: (signal: AbortSignal) => Promise<void>) {
    if (busy) return;
    setBusy(true);
    setError("");
    const controller = new AbortController();
    pending.current = controller;
    try {
      await action(controller.signal);
    } catch {
      if (alive.current && !controller.signal.aborted)
        setError(
          t("恢复操作未完成：请检查密钥、密码、备份完整性及 Web 容量限制。"),
        );
    } finally {
      if (alive.current) setBusy(false);
    }
  }
  const normalize = (value: string) =>
    value.toLowerCase().replace(/[\s-]/g, "");
  return (
    <section class="recovery-panel">
      <h2>{t("离线应急恢复")}</h2>
      <p>
        {t("密钥与完整应急备份必须分开保存。仅有密钥不能找回丢失且没有备份的资料。更换或停用密钥不会撤销旧备份。")}</p>
      <fieldset disabled={busy}>
        {locked ? (
          <>
            {!exists && (
              <label>
                {t("应急备份文件")}<input
                  type="file"
                  accept=".pvbackup,.json,application/octet-stream"
                  onChange={(e) => setFile(e.currentTarget.files?.[0])}
                />
              </label>
            )}
            <label>
              {t("恢复密钥")}<input
                type="password"
                value={key}
                onInput={(e) => setKey(e.currentTarget.value)}
                autoComplete="off"
              />
            </label>
            <label>
              {t("新主密码（至少 10 个字符）")}<input
                type="password"
                value={newPassword}
                onInput={(e) => setNewPassword(e.currentTarget.value)}
                autoComplete="new-password"
              />
            </label>
            <label>
              {t("确认新密码")}<input
                type="password"
                value={confirmPassword}
                onInput={(e) => setConfirmPassword(e.currentTarget.value)}
                autoComplete="new-password"
              />
            </label>
            <button
              type="button"
              disabled={
                !key ||
                newPassword.length < 10 ||
                newPassword !== confirmPassword ||
                (!exists && !file)
              }
              onClick={() =>
                run(async (signal) => {
                  if (file && file.size > 64 * 1024 * 1024)
                    throw new Error("Too large");
                  await recover(
                    key,
                    newPassword,
                    !exists ? await file!.text() : undefined,
                    signal,
                  );
                  if (alive.current) {
                    setKey("");
                    setNewPassword("");
                    setConfirmPassword("");
                    await onComplete();
                  }
                })
              }
            >
              {t("恢复资料库")}</button>
          </>
        ) : (
          <>
            <p>{enabled ? t("已启用恢复密钥") : t("尚未启用恢复密钥")}</p>
            {generated ? (
              <>
                <code>{key}</code>
                <button
                  type="button"
                  onClick={() =>
                    void copy(key).catch(() => setError(t("无法复制密钥")))
                  }
                >
                  {t("复制密钥")}</button>
                <label>
                  {t("再次输入完整密钥")}<input
                    type="password"
                    value={confirmation}
                    onInput={(e) => setConfirmation(e.currentTarget.value)}
                    autoComplete="off"
                  />
                </label>
                <label class="share-choice">
                  <input
                    type="checkbox"
                    checked={saved}
                    onChange={(e) => setSaved(e.currentTarget.checked)}
                  />
                  {t("已在库外单独保存密钥")}</label>
              </>
            ) : (
              enabled && (
                <label>
                  {t("恢复密钥")}<input
                    type="password"
                    value={key}
                    onInput={(e) => setKey(e.currentTarget.value)}
                    autoComplete="off"
                  />
                </label>
              )
            )}
            <label>
              {t("当前主密码")}<input
                type="password"
                value={password}
                onInput={(e) => setPassword(e.currentTarget.value)}
                autoComplete="current-password"
              />
            </label>
            <button
              type="button"
              disabled={generated}
              onClick={() =>
                run(async () => {
                  const result = await command({ op: "recovery-generate" });
                  if (alive.current) {
                    setKey(result.key);
                    setGenerated(true);
                    setSaved(false);
                    setConfirmation("");
                  }
                })
              }
            >
              {t("生成 / 更换密钥")}</button>
            {generated ? (
              <button
                type="button"
                disabled={
                  !saved ||
                  !password ||
                  normalize(key) !== normalize(confirmation)
                }
                onClick={() =>
                  run(async () => {
                    await command({
                      op: "recovery-enable",
                      key,
                      currentPassword: password,
                    });
                    if (alive.current) {
                      setEnabled(true);
                      setGenerated(false);
                      setPassword("");
                      setConfirmation("");
                    }
                  })
                }
              >
                {t("确认启用")}</button>
            ) : (
              enabled && (
                <>
                  <button
                    type="button"
                    disabled={!key}
                    onClick={() =>
                      run(async () => {
                        const result = await command({
                          op: "recovery-export",
                          key,
                        });
                        if (!alive.current) return;
                        const url = URL.createObjectURL(
                          new Blob([result.content], {
                            type: "application/octet-stream",
                          }),
                        );
                        const a = document.createElement("a");
                        a.href = url;
                        a.download = "PasswordVault-emergency.pvbackup";
                        a.click();
                        setTimeout(() => URL.revokeObjectURL(url), 1000);
                        setKey("");
                      })
                    }
                  >
                    {t("导出应急备份")}</button>
                  <button
                    type="button"
                    disabled={!password}
                    onClick={() =>
                      run(async () => {
                        await command({
                          op: "recovery-disable",
                          currentPassword: password,
                        });
                        if (alive.current) {
                          setEnabled(false);
                          setKey("");
                          setPassword("");
                        }
                      })
                    }
                  >
                    {t("停用恢复密钥")}</button>
                </>
              )
            )}
          </>
        )}
      </fieldset>
      {busy && <p role="status">{t("正在处理…")}</p>}
      {error && <p role="alert">{error}</p>}
    </section>
  );
}

export function RecoveryDialog({
  exists,
  close,
  onComplete,
  copy,
}: {
  exists: boolean;
  close: () => void;
  onComplete: () => Promise<void>;
  copy: (value: string) => Promise<void>;
}) {
  useLocale();
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    dialog.current?.showModal();
  }, []);
  return (
    <dialog ref={dialog} class="share-dialog" onCancel={close}>
      <RecoveryPanel
        locked
        exists={exists}
        onComplete={onComplete}
        copy={copy}
      />
      <button type="button" onClick={close}>
        {t("关闭")}</button>
    </dialog>
  );
}
