import {t,useLocale} from "./i18n";
import { useEffect, useRef, useState } from "preact/hooks";
import { command } from "./client";
import { ShareService } from "./share-service";

export function ShareDialog({
  id,
  settings,
  close,
  refresh,
  copy,
}: {
  id: string;
  settings: any;
  close: () => void;
  refresh: () => Promise<void>;
  copy: (value: string) => Promise<void>;
}) {
  useLocale();
  const [endpoint, setEndpoint] = useState(settings.shareServiceURL ?? "");
  const [token, setToken] = useState(settings.shareServiceToken ?? "");
  const [attachments, setAttachments] = useState<any[]>([]);
  const [chosen, setChosen] = useState<Set<string>>(new Set());
  const [managed, setManaged] = useState<any[]>([]);
  const [fields, setFields] = useState<string[]>([]);
  const [selected, setSelected] = useState(
    new Set(["title", "username", "password", "url", "note"]),
  );
  const [expiry, setExpiry] = useState(604800);
  const [email, setEmail] = useState("");
  const [restricted, setRestricted] = useState(false);
  const [mail, setMail] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [link, setLink] = useState("");
  const pending = useRef<AbortController>();
  const mounted = useRef(true);
  const created = useRef<{ client: ShareService; id: string }>();
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    dialog.current?.showModal();
    void command({ op: "share-options", id })
      .then((value) => {
        if (mounted.current) {setFields(value.fields);setAttachments(value.attachments??[]);}
      })
      .catch(() => {
        if (mounted.current) setError(t("无法读取条目"));
      });
    return () => {
      mounted.current = false;
      pending.current?.abort();
      created.current = undefined;
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
      if (mounted.current && !controller.signal.aborted)
        setError(t("分享未完成，请检查配置、网络、CORS 及权限。"));
    } finally {
      if (mounted.current) setBusy(false);
    }
  }
  return (
    <dialog
      ref={dialog}
      class="share-dialog"
      onCancel={close}
      aria-labelledby="share-title"
    >
      <h2 id="share-title">{t("临时加密分享")}</h2>
      <p>
        {t("分享所选字段的副本，更改原条目不会更新链接。撤销无法收回已下载内容。")}</p>
      <fieldset disabled={busy}>
        <label>
          {t("服务地址（HTTPS）")}<input
            value={endpoint}
            onInput={(e) => setEndpoint(e.currentTarget.value)}
          />
        </label>
        <label>
          {t("服务访问令牌")}<input
            type="password"
            autoComplete="off"
            value={token}
            onInput={(e) => setToken(e.currentTarget.value)}
          />
        </label>
        <button
          onClick={() =>
            run(async (signal) => {
              const client = new ShareService(endpoint, token);
              const info = await client.capabilities(signal);
              await client.list(signal);
              await command({
                op: "settings",
                settings: {
                  shareServiceURL: endpoint,
                  shareServiceToken: token,
                },
              });
              await refresh();
              if (mounted.current) setMail(info.emailVerification === true);
            })
          }
        >
          {t("检查并保存配置")}</button>
        <p>{t("仅分享勾选的字段和附件，不包含密码历史、Passkey 私钥或原始导入资料。")}</p>
        {attachments.map(file=><label class="share-choice"><input type="checkbox" checked={chosen.has(file.id)} onChange={e=>{const next=new Set(chosen);if(e.currentTarget.checked)next.add(file.id);else next.delete(file.id);setChosen(next);}}/>{file.name}</label>)}
        {fields.map((field) => (
          <label key={field} class="share-choice">
            <input
              type="checkbox"
              checked={selected.has(field)}
              onChange={(e) => {
                const next = new Set(selected);
                if (e.currentTarget.checked) next.add(field);
                else next.delete(field);
                setSelected(next);
              }}
            />
            {(
              {
                title: t("标题"),
                username: t("用户名"),
                password: t("密码"),
                url: t("网址"),
                note: t("备注 / 笔记摘要"),
                secret: t("验证码密钥"),
                mnemonic: t("助记词"),
                privateKey: t("私钥"),
                address: t("地址"),
                network: t("网络"),
                category: t("分类"),
                tags: t("标签"),
                card: t("银行卡资料（含安全码）"), identity: t("身份资料"), customFields: t("全部自定义字段（含隐藏值）"),
              } as Record<string, string>
            )[field] ?? field}
          </label>
        ))}
        <label>
          {t("有效期")}<select
            value={expiry}
            onChange={(e) => setExpiry(Number(e.currentTarget.value))}
          >
            <option value={3600}>{t("一小时")}</option>
            <option value={86400}>{t("一天")}</option>
            <option value={604800}>{t("七天")}</option>
            <option value={2592000}>{t("三十天")}</option>
          </select>
        </label>
        <label class="share-choice">
          <input
            type="checkbox"
            disabled={!mail}
            checked={restricted}
            onChange={(e) => setRestricted(e.currentTarget.checked)}
          />
          {t("仅指定邮箱可查看")}</label>
        {restricted && (
          <label>
            {t("接收邮箱")}<input
              type="email"
              value={email}
              onInput={(e) => setEmail(e.currentTarget.value)}
            />
          </label>
        )}
        <button
          disabled={
            !fields.some((field) => selected.has(field)) ||
            (restricted && !email)
          }
          onClick={() =>
            run(async (signal) => {
              const envelope = await command({
                op: "share-seal",
                id,
                fields: fields.filter((field) => selected.has(field)),
                attachmentIds: [...chosen],
              });
              if (signal.aborted) return;
              const client = new ShareService(endpoint, token);
              const url = await client.create(
                envelope,
                expiry,
                restricted ? email : undefined,
                signal,
              );
              if (mounted.current) {
                created.current = { client, id: envelope.id };
                setLink(url);
              }
            })
          }
        >
          {t("创建分享链接")}</button>
        {link && (
          <section>
            <p>{t("完整链接包含解密密钥；关闭后不能从服务端重新取回。")}</p>
            <button onClick={() => copy(link)}>{t("复制完整链接")}</button>
            <button
              onClick={() =>
                run(async (signal) => {
                  if (created.current) {
                    await created.current.client.revoke(
                      created.current.id,
                      signal,
                    );
                    if (mounted.current) setLink("");
                  }
                })
              }
            >
              {t("撤销链接")}</button>
          </section>
        )}
        <hr/><h3>{t("管理尚未到期的链接")}</h3>
        <button onClick={()=>run(async signal=>{const result=await new ShareService(endpoint,token).list(signal);if(mounted.current)setManaged(result.shares??[]);})}>{t("刷新分享列表")}</button>
        {managed.map(share=><article key={share.id}><code>{share.id}</code><p>{new Date(share.expiry).toLocaleString()} {share.restricted?t("指定邮箱"):''}</p><button onClick={()=>{if(!confirm(t("撤销此链接？已下载的内容无法收回。")))return;void run(async signal=>{const client=new ShareService(endpoint,token);await client.revoke(share.id,signal);const result=await client.list(signal);if(mounted.current){setManaged(result.shares??[]);if(created.current?.id===share.id)setLink('');}});}}>{t("撤销")}</button></article>)}
      </fieldset>
      {error && <p role="alert">{error}</p>}
      {busy && <p role="status">{t("正在处理…")}</p>}
      <button onClick={close}>{t("关闭")}</button>
    </dialog>
  );
}
