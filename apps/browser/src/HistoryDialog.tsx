import {t,useLocale} from "./i18n";
import { useEffect, useRef, useState } from "preact/hooks";
import { command } from "./client";
export function HistoryDialog({
  id,
  close,
  refresh,
  readOnly=false,
}: {
  id: string;
  close: () => void;
  refresh: () => Promise<void>;
  readOnly?: boolean;
}) {
  useLocale();
  const [enabled, setEnabled] = useState(false);
  const [rows, setRows] = useState<any[]>([]);
  const [total, setTotal] = useState(0);
  const [selected, setSelected] = useState<any>();
  const [reveal, setReveal] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [action, setAction] = useState("");
  const alive = useRef(true);
  const dialog = useRef<HTMLDialogElement>(null);
  async function load(append = false) {
    const status = await command({ op: "history-status" });
    const result = await command({
      op: "history-list",
      id,
      offset: append ? rows.length : 0,
    });
    if (!alive.current) return;
    setEnabled(status.enabled);
    setTotal(result.total);
    setRows(append ? [...rows, ...result.revisions] : result.revisions);
  }
  async function run(work: () => Promise<void>) {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      await work();
    } catch {
      if (alive.current) setError(t("历史操作未完成，请检查权限与资料完整性。"));
    } finally {
      if (alive.current) setBusy(false);
    }
  }
  useEffect(() => {
    dialog.current?.showModal();
    void run(() => load());
    return () => {
      alive.current = false;
    };
  }, []);
  return (
    <dialog ref={dialog} class="share-dialog" onCancel={close}>
      <h2>{t("完整条目历史")}</h2>
      <fieldset disabled={busy}>
        {!enabled ? (
          <>
            <p>
              {t("启用将升级资料库，旧客户端不能打开。旧秘密及附件会保留；升级前的加密快照会在本地保留。")}</p>
            <button
              onClick={() =>
                run(async () => {
                  await command({ op: "history-enable" });
                  await load();
                  await refresh();
                })
              }
            >
              {t("启用完整历史")}</button>
          </>
        ) : (
          <>
            <p>{t("保留当前内容。个人库清理本机旧版本；对等资料库仅隐藏旧版本，旧内容仍在同步日志中。已有备份不受影响。")}</p>
            <select
              aria-label={t("选择历史版本")}
              value={selected?.id ?? ""}
              onChange={(e) => {
                setSelected(
                  rows.find((row) => row.id === e.currentTarget.value),
                );
                setReveal(false);
                setAction("");
              }}
            >
              <option value="">{t("选择版本")}</option>
              {rows.map((row) => (
                <option key={row.id} value={row.id}>
                  {new Date(row.capturedAt).toLocaleString()} ·{" "}
                  {row.item?.title ?? t("已删除")}
                </option>
              ))}
            </select>
            {rows.length < total && (
              <button onClick={() => run(() => load(true))}>{t("加载更多")}</button>
            )}
            {selected && (
              <>
                <label class="share-choice">
                  <input
                    type="checkbox"
                    checked={reveal}
                    onChange={(e) => setReveal(e.currentTarget.checked)}
                  />
                  {t("显示完整内容（包含敏感信息）")}</label>
                {reveal && (
                  <pre class="history-preview">
                    {JSON.stringify(selected.item, null, 2)}
                  </pre>
                )}
                <button
                  disabled={!selected.item || readOnly}
                  onClick={() => setAction("restore")}
                >
                  {t("恢复此版本")}</button>
              </>
            )}
            <button onClick={() => setAction("prune")}>{t("清理旧版本")}</button>
            {action && (
              <section>
                <p>
                  {action === "prune"
                    ? t("确认清理本机旧版本？此操作不能撤销，当前内容保留。")
                    : t("确认恢复？当前内容会保留在历史中。")}
                </p>
                <button
                  onClick={() =>
                    run(async () => {
                      await command(
                        action === "prune"
                          ? { op: "history-prune", id }
                          : {
                              op: "history-restore",
                              id,
                              revisionId: selected.id,
                              time: new Date().toISOString(),
                            },
                      );
                      if (!alive.current) return;
                      setSelected(undefined);
                      setReveal(false);
                      setAction("");
                      await load();
                      await refresh();
                    })
                  }
                >
                  {t("确认")}</button>
                <button onClick={() => setAction("")}>{t("取消")}</button>
              </section>
            )}
          </>
        )}
      </fieldset>
      {error && <p role="alert">{error}</p>}
      <button onClick={close}>{t("关闭")}</button>
    </dialog>
  );
}
