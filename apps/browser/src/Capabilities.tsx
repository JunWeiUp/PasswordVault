import {t,useLocale} from "./i18n";
import { useEffect, useRef, useState } from "preact/hooks";
import { command } from "./client";
import { fmt } from "./i18n";
import { groupSecurityFindings, type SecurityGroupKey } from "./security-groups";

type Item = { id: string; type: string; title: string; [key: string]: any };
const card = [["cardholder", "持卡人"], ["number", "卡号"], ["expiryMonth", "到期月"], ["expiryYear", "到期年"], ["securityCode", "安全码"], ["brand", "卡组织"]];
const identity = [["firstName", "名"], ["lastName", "姓"], ["email", "邮箱"], ["phone", "电话"], ["address1", "地址"], ["address2", "地址补充"], ["city", "城市"], ["region", "省 / 州"], ["postalCode", "邮编"], ["country", "国家"], ["company", "公司"]];
export function structuredLabel(key:string) {return t([...card,...identity].find(([name])=>name===key)?.[1]??key);}
export function StructuredFieldsEditor({ item, onChange }: { item: Item; onChange: (item: Item) => void }) {
  useLocale();
  const group = item.type === "creditCard" ? "card" : item.type === "identity" ? "identity" : null;
  const fields = item.customFields ?? [];
  function custom(index: number, key: string, value: string) { onChange({ ...item, customFields: fields.map((field: any, i: number) => i === index ? { ...field, [key]: value } : field) }); }
  return <fieldset><legend>{t("结构化资料与自定义字段")}</legend>
    {group && (group === "card" ? card : identity).map(([key, label]) => <label key={key}>{t(label)}<input autoComplete="off" type={key === "number" || key === "securityCode" ? "password" : "text"} value={item[group]?.[key] ?? ""} onInput={e => onChange({ ...item, [group]: { ...item[group], [key]: e.currentTarget.value } })} /></label>)}
    {fields.map((field: any, index: number) => <div key={field.id}><label>{t("字段名称")}<input value={field.label} onInput={e => custom(index, "label", e.currentTarget.value)} /></label>
      <label>{t("分组")}<input value={field.group ?? ""} onInput={e => custom(index, "group", e.currentTarget.value)} /></label>
      <div class="seg-group"><span class="seg-label">{t("类型")}</span><div class="seg-bar" role="radiogroup" aria-label={t("类型")}>{([["concealed", t("隐藏内容")], ["text", t("文字")], ["url", t("网址")], ["email", t("邮箱")], ["date", t("日期")]] as const).map(([val, label]) => <button type="button" role="radio" aria-checked={field.kind === val} class={field.kind === val ? "on" : ""} onClick={() => custom(index, "kind", val)}>{label}</button>)}</div></div>
      <label>{t("内容")}<input autoComplete="off" type={field.kind === "concealed" ? "password" : "text"} value={field.value} onInput={e => custom(index, "value", e.currentTarget.value)} /></label>
      <button type="button" onClick={() => onChange({ ...item, customFields: fields.filter((_: any, i: number) => i !== index) })}>{t("移除字段")}</button></div>)}
    {(item.importSource?.attachments ?? []).map((attachment: any, index: number) => <button type="button" key={`attachment-${index}`} onClick={() => { const bytes = Uint8Array.from(atob(attachment.data), c => c.charCodeAt(0)); const url = URL.createObjectURL(new Blob([bytes])); const link = document.createElement("a"); link.href = url; link.download = String(attachment.name || "attachment").split(/[\\/]/).pop() || "attachment"; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); }}>{t("下载附件：")}{attachment.name}</button>)}
    <button type="button" disabled={fields.length >= 256} onClick={() => onChange({ ...item, customFields: [...fields, { id: crypto.randomUUID(), label: "", value: "", kind: "concealed" }] })}>{t("添加字段")}</button>
  </fieldset>;
}
function base64(bytes: Uint8Array) { let result = ""; for (let i = 0; i < bytes.length; i += 8192) result += String.fromCharCode(...bytes.subarray(i, i + 8192)); return btoa(result); }
export function ImportReviewPanel({ onComplete }: { onComplete: () => Promise<void> }) {
  useLocale();
  const [source, setSource] = useState(""); const [format, setFormat] = useState("csv");
  const [preview, setPreview] = useState<any>(); const [mapping, setMapping] = useState<Record<string, string>>({}); const [choices, setChoices] = useState<Record<string, string>>({});
  const [checkedMapping, setCheckedMapping] = useState("{}");
  const [busy, setBusy] = useState(false); const [message, setMessage] = useState(""); const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);
  async function inspect(data = source, kind = format, fields = mapping) {
    setBusy(true); setMessage("");
    try { const result = await command({ op: "import-preview", format: kind, data, mapping: fields }); if (alive.current) { setPreview(result); setCheckedMapping(JSON.stringify(fields)); setChoices({}); } }
    catch { if (alive.current) { setPreview(undefined); setMessage(t("预检未完成；资料库未更改。")); } }
    finally { if (alive.current) setBusy(false); }
  }
  async function commit() {
    setBusy(true);
    try { const result = await command({ op: "import-commit", format, data: source, mapping, choices }); await onComplete(); if (alive.current) { setSource(""); setPreview(undefined); setMessage(t("已导入 {added} 项，跳过 {skipped} 项。").replace("{added}",String(result.added)).replace("{skipped}",String(result.skipped))); } }
    catch { if (alive.current) setMessage(t("导入失败，原有数据已保留。")); }
    finally { if (alive.current) setBusy(false); }
  }
  return <section><h3>{t("迁入资料")}</h3><p>{t("选择浏览器 CSV、1Password .1pux 或 FIDO CXF（.json）。默认跳过重复项，不覆盖同名记录，原文件不会删除。")}</p>
    <input aria-label={t("导入文件")} type="file" accept=".csv,.1pux,.json,.cxf" disabled={busy} onChange={async e => { const file = e.currentTarget.files?.[0]; e.currentTarget.value = ""; if (!file) return; if (file.size > 64 * 1024 * 1024) { setMessage(t("文件超过 64 MiB 限制。")); return; } try { const data = base64(new Uint8Array(await file.arrayBuffer())); const name = file.name.toLowerCase(); const kind = name.endsWith(".1pux") ? "1pux" : name.endsWith(".json") || name.endsWith(".cxf") ? "cxf" : "csv"; setSource(data); setFormat(kind); setMapping({}); await inspect(data, kind, {}); } catch { setMessage(t("读取文件失败。")); } }} />
    {message && <p role="status">{message}</p>}
    {preview && <><fieldset disabled={busy}><legend>{t("导入预检")}</legend>{format === "csv" && <>{["title", "username", "password", "url", "notes"].map(key => <label key={key}>{t(({title:"标题",username:"用户名",password:"密码",url:"网址",notes:"备注"} as Record<string,string>)[key])}<select value={mapping[key] ?? ""} onChange={e => { const next = { ...mapping }; if (e.currentTarget.value) next[key] = e.currentTarget.value; else delete next[key]; setMapping(next); }}><option value="">{t("自动匹配")}</option>{preview.columns.map((column: string) => <option>{column}</option>)}</select></label>)}<button onClick={() => inspect()}>{t("重新预检映射")}</button></>}
    <table class="status-table"><thead><tr><th>{t("导入")}</th><th>{t("标题")}</th><th>{t("用户名")}</th><th>{t("状态")}</th></tr></thead><tbody>
    {preview.rows.map((row: any) => { const add = choices[row.index] ? choices[row.index] === "add" : !row.duplicateIds.length; return <tr key={row.index}><td><input type="checkbox" aria-label={fmt(t("导入 {title}"), { title: row.item.title ?? "" })} checked={add} onChange={e => setChoices({ ...choices, [row.index]: e.currentTarget.checked ? "add" : "skip" })} /></td><td>{row.item.title}</td><td>{row.item.username ?? ""}</td><td>{row.duplicateIds.length > 0 ? <span class="pill warn">{t("重复或同名")}</span> : row.warnings.length ? <span class="pill warn">{t("需要检查")}</span> : <span class="pill ok">{t("新增")}</span>}{!add && <span class="pill">{t("跳过")}</span>}{row.warnings.map((warning: string) => <small class="status-note">{warning}</small>)}</td></tr>; })}
    {preview.failures.map((failure: any) => <tr role="alert"><td></td><td colSpan={2}>{t("行")}{failure.row}</td><td><span class="pill err">{t("无法导入")}</span><small class="status-note">{failure.reason}</small></td></tr>)}
    </tbody></table><button disabled={!preview.rows.length || JSON.stringify(mapping) !== checkedMapping} onClick={commit}>{t("确认导入")}</button></fieldset></>}
  </section>;
}

function securityFindingTitle(kind: string): string {
  switch (kind) {
    case "passwordHealth": return t("密码需要检查");
    case "twoFactorAvailable": return t("可启用双重验证");
    case "passkeyAvailable": return t("支持通行密钥");
    case "siteIncident": return t("网站安全事件");
    case "duplicateEntry": return t("重复条目");
    default: return t("其他安全提醒");
  }
}
function securityGroupTitle(key: SecurityGroupKey): string {
  return ({ weak: t("弱密码"), reused: t("重复使用的密码"), breach: t("泄露的密码"), expired: t("过期的密码"), twoFactor: t("可启用双重验证"), passkey: t("支持通行密钥"), other: t("其他安全提醒") } as Record<SecurityGroupKey, string>)[key];
}
function securityFindingDetails(finding: any): string {
  if (finding.kind !== "passwordHealth") return "";
  return [finding.weak === true ? t("密码较弱") : "", finding.reused === true ? t("密码重复使用") : "", finding.expired === true ? t("密码已超过设置的有效期") : ""].filter(Boolean).join(" · ");
}

export function SecurityCenterPanel({ items, openItem }: { items: Item[]; openItem: (id: string) => void }) {
  useLocale();
  const [report, setReport] = useState<any>(); const [enabled, setEnabled] = useState(false); const [busy, setBusy] = useState(false); const [results, setResults] = useState<Record<string, string>>({}); const [message, setMessage] = useState(""); const [breached, setBreached] = useState<string[]>([]);
  const abort = useRef<AbortController>(); const alive = useRef(true);
  useEffect(() => { void refresh(); return () => { alive.current = false; abort.current?.abort(); }; }, []);
  async function refresh() { try { const value = await command({ op: "security-audit" }); if (alive.current) setReport(value); } catch { if (alive.current) setMessage(t("本地检查未完成。")); } }
  async function check() {
    abort.current?.abort(); const controller = new AbortController(); abort.current = controller; setBusy(true); setResults({}); setBreached([]);
    for (const item of items.filter(i => i.type === "password" && !i.isDeleted)) {
      if (controller.signal.aborted) break;
      let outcome = t("无密码可检查");
      try {
        const passwords = [...new Set([item.password, ...(item.accounts ?? []).map((a: any) => a.password)].filter((p): p is string => typeof p === "string" && p.length > 0))];
        let count = 0;
        for (const password of passwords) {
          const parts = await command({ op: "breach-request", password });
          if (!/^[0-9A-F]{5}$/.test(parts.prefix)) throw Error("Invalid prefix");
          const response = await fetch(`https://api.pwnedpasswords.com/range/${parts.prefix}`, { signal: controller.signal, credentials: "omit", cache: "no-store", redirect: "error", referrerPolicy: "no-referrer", headers: { "Add-Padding": "true" } });
          if (!response.ok) throw Error("Incomplete"); const text = await response.text(); if (text.length > 4 * 1024 * 1024) throw Error("Oversized");
          count += (await command({ op: "breach-response", suffix: parts.suffix, response: text })).count;
        }
        if (passwords.length) outcome = count > 0 ? t("发现泄露记录，请更换密码") : t("本次查询未发现记录");
        if (count > 0 && !controller.signal.aborted && alive.current) setBreached(current => [...current, item.id]);
      } catch { outcome = t("检查未完成，请重试"); }
      if (!controller.signal.aborted && alive.current) setResults(current => ({ ...current, [item.id]: outcome }));
    }
    if (alive.current) setBusy(false);
  }
  return <section><h3>{t("安全中心")}</h3><p>{t("网站目录覆盖有限，未列入的网站未检查；提示不代表账号已开启验证。目录更新：")}{report?.catalogUpdatedAt ?? t("未知")}</p><button onClick={refresh}>{t("重新检查")}</button>
    <label>{t("导入更新目录")}<input type="file" accept=".json" onChange={async e => { const file = e.currentTarget.files?.[0]; e.currentTarget.value = ""; if (!file) return; try { if (file.size > 8 * 1024 * 1024) throw Error("Too large"); await command({ op: "security-catalog", catalog: JSON.parse(await file.text()) }); await refresh(); } catch { setMessage(t("目录导入失败，已保留原目录。")); } }} /></label>
    <details><summary>{t("数据来源与许可")}</summary><p>{report?.catalogLicense}</p>{report?.catalogSources?.map((source: any) => <p><a href={source.url} target="_blank" rel="noreferrer">{source.name}</a> · {source.revision}</p>)}<pre style={{ whiteSpace: "pre-wrap" }}>{report?.catalogLicenseText}</pre></details>
    {groupSecurityFindings(report?.findings ?? [], items.filter(i => breached.includes(i.id)).map(i => ({ id: i.id, title: i.title }))).map(group => <section class="audit-group" key={group.key}><header><strong>{securityGroupTitle(group.key)}</strong><span class={`pill ${group.count ? (group.key === "twoFactor" || group.key === "passkey" ? "" : "warn") : "ok"}`}>{fmt(t("{count} 项"), { count: group.count })}</span></header>
    {group.findings.map((finding: any) => finding.kind === "breach" ? <article key={finding.key}><button onClick={() => openItem(finding.id)}>{finding.title ?? finding.id} · {t("发现泄露记录，请更换密码")}</button></article> : <article key={`${group.key}:${finding.key}`}><button onClick={() => openItem(finding.id)}>{finding.title ?? finding.id} · {securityFindingTitle(finding.kind)}</button>{securityFindingDetails(finding) && <p>{securityFindingDetails(finding)}</p>}{finding.ignored && <span>{t("已忽略")}</span>}{finding.source && <a href={finding.source} target="_blank" rel="noreferrer">{t("查看依据")}</a>}{finding.incident && <a href={finding.incident.source} target="_blank" rel="noreferrer">{finding.incident.title}</a>}<button onClick={async () => { try { await command({ op: "security-ignore", key: finding.key, ignored: !finding.ignored }); await refresh(); } catch { setMessage(t("无法保存忽略设置。")); } }}>{finding.ignored ? t("恢复提醒") : t("忽略此项")}</button></article>)}</section>)}
    <label><input type="checkbox" checked={enabled} onChange={e => { setEnabled(e.currentTarget.checked); if (!e.currentTarget.checked) { abort.current?.abort(); setResults({}); setBreached([]); } }} />{t("允许本次联网泄露密码检查")}</label>
    <p>{t("仅向 Have I Been Pwned 发送 SHA-1 前 5 位，并请求填充响应。不会发送密码、完整哈希、账号或站点；网络失败不表示安全。")}</p>
    <button disabled={!enabled || busy} onClick={check}>{t("检查 / 重新检查")}</button>{items.filter(i => i.type === "password" && !i.isDeleted).map(item => <p key={item.id}>{item.title}: {results[item.id] ?? t("未检查")}</p>)}{message && <p role="alert">{message}</p>}
  </section>;
}
