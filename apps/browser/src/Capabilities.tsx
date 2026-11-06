import {t,useLocale} from "./i18n";
import { useEffect, useRef, useState } from "preact/hooks";
import { command } from "./client";

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
      <label>{t("分组")}<input value={field.group ?? ""} onInput={e => custom(index, "group", e.currentTarget.value)} /></label><label>{t("类型")}<select value={field.kind} onChange={e => custom(index, "kind", e.currentTarget.value)}><option value="concealed">{t("隐藏内容")}</option><option value="text">{t("文字")}</option><option value="url">{t("网址")}</option><option value="email">{t("邮箱")}</option><option value="date">{t("日期")}</option></select></label>
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
  return <section><h3>{t("迁入资料")}</h3><p>{t("选择浏览器 CSV 或 1Password .1pux。默认跳过重复项，不覆盖同名记录，原文件不会删除。")}</p>
    <input aria-label={t("导入文件")} type="file" accept=".csv,.1pux" disabled={busy} onChange={async e => { const file = e.currentTarget.files?.[0]; e.currentTarget.value = ""; if (!file) return; if (file.size > 64 * 1024 * 1024) { setMessage(t("文件超过 64 MiB 限制。")); return; } try { const data = base64(new Uint8Array(await file.arrayBuffer())); const kind = file.name.toLowerCase().endsWith(".1pux") ? "1pux" : "csv"; setSource(data); setFormat(kind); setMapping({}); await inspect(data, kind, {}); } catch { setMessage(t("读取文件失败。")); } }} />
    {message && <p role="status">{message}</p>}
    {preview && <><fieldset disabled={busy}><legend>{t("导入预检")}</legend>{format === "csv" && <>{["title", "username", "password", "url", "notes"].map(key => <label key={key}>{t(({title:"标题",username:"用户名",password:"密码",url:"网址",notes:"备注"} as Record<string,string>)[key])}<select value={mapping[key] ?? ""} onChange={e => { const next = { ...mapping }; if (e.currentTarget.value) next[key] = e.currentTarget.value; else delete next[key]; setMapping(next); }}><option value="">{t("自动匹配")}</option>{preview.columns.map((column: string) => <option>{column}</option>)}</select></label>)}<button onClick={() => inspect()}>{t("重新预检映射")}</button></>}
    {preview.rows.map((row: any) => <article key={row.index}><label><input type="checkbox" checked={choices[row.index] ? choices[row.index] === "add" : !row.duplicateIds.length} onChange={e => setChoices({ ...choices, [row.index]: e.currentTarget.checked ? "add" : "skip" })} />{row.item.title} {row.duplicateIds.length > 0 && t("（重复或同名）")}</label>{row.warnings.map((warning: string) => <p>{warning}</p>)}</article>)}
    {preview.failures.map((failure: any) => <p role="alert">{t("行")}{failure.row}: {failure.reason}</p>)}<button disabled={!preview.rows.length || JSON.stringify(mapping) !== checkedMapping} onClick={commit}>{t("确认导入")}</button></fieldset></>}
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
function securityFindingDetails(finding: any): string {
  if (finding.kind !== "passwordHealth") return "";
  return [finding.weak === true ? t("密码较弱") : "", finding.reused === true ? t("密码重复使用") : "", finding.expired === true ? t("密码已超过设置的有效期") : ""].filter(Boolean).join(" · ");
}

export function SecurityCenterPanel({ items, openItem }: { items: Item[]; openItem: (id: string) => void }) {
  useLocale();
  const [report, setReport] = useState<any>(); const [enabled, setEnabled] = useState(false); const [busy, setBusy] = useState(false); const [results, setResults] = useState<Record<string, string>>({}); const [message, setMessage] = useState("");
  const abort = useRef<AbortController>(); const alive = useRef(true);
  useEffect(() => { void refresh(); return () => { alive.current = false; abort.current?.abort(); }; }, []);
  async function refresh() { try { const value = await command({ op: "security-audit" }); if (alive.current) setReport(value); } catch { if (alive.current) setMessage(t("本地检查未完成。")); } }
  async function check() {
    abort.current?.abort(); const controller = new AbortController(); abort.current = controller; setBusy(true); setResults({});
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
      } catch { outcome = t("检查未完成，请重试"); }
      if (!controller.signal.aborted && alive.current) setResults(current => ({ ...current, [item.id]: outcome }));
    }
    if (alive.current) setBusy(false);
  }
  return <section><h3>{t("安全中心")}</h3><p>{t("网站目录覆盖有限，未列入的网站未检查；提示不代表账号已开启验证。目录更新：")}{report?.catalogUpdatedAt ?? t("未知")}</p><button onClick={refresh}>{t("重新检查")}</button>
    <label>{t("导入更新目录")}<input type="file" accept=".json" onChange={async e => { const file = e.currentTarget.files?.[0]; e.currentTarget.value = ""; if (!file) return; try { if (file.size > 8 * 1024 * 1024) throw Error("Too large"); await command({ op: "security-catalog", catalog: JSON.parse(await file.text()) }); await refresh(); } catch { setMessage(t("目录导入失败，已保留原目录。")); } }} /></label>
    <details><summary>{t("数据来源与许可")}</summary><p>{report?.catalogLicense}</p>{report?.catalogSources?.map((source: any) => <p><a href={source.url} target="_blank" rel="noreferrer">{source.name}</a> · {source.revision}</p>)}<pre style={{ whiteSpace: "pre-wrap" }}>{report?.catalogLicenseText}</pre></details>
    {report?.findings.map((finding: any) => <article key={finding.key}><button onClick={() => openItem(finding.id)}>{finding.title ?? finding.id} · {securityFindingTitle(finding.kind)}</button>{securityFindingDetails(finding) && <p>{securityFindingDetails(finding)}</p>}{finding.ignored && <span>{t("已忽略")}</span>}{finding.source && <a href={finding.source} target="_blank" rel="noreferrer">{t("查看依据")}</a>}{finding.incident && <a href={finding.incident.source} target="_blank" rel="noreferrer">{finding.incident.title}</a>}<button onClick={async () => { try { await command({ op: "security-ignore", key: finding.key, ignored: !finding.ignored }); await refresh(); } catch { setMessage(t("无法保存忽略设置。")); } }}>{finding.ignored ? t("恢复提醒") : t("忽略此项")}</button></article>)}
    <label><input type="checkbox" checked={enabled} onChange={e => { setEnabled(e.currentTarget.checked); if (!e.currentTarget.checked) { abort.current?.abort(); setResults({}); } }} />{t("允许本次联网泄露密码检查")}</label>
    <p>{t("仅向 Have I Been Pwned 发送 SHA-1 前 5 位，并请求填充响应。不会发送密码、完整哈希、账号或站点；网络失败不表示安全。")}</p>
    <button disabled={!enabled || busy} onClick={check}>{t("检查 / 重新检查")}</button>{items.filter(i => i.type === "password" && !i.isDeleted).map(item => <p key={item.id}>{item.title}: {results[item.id] ?? t("未检查")}</p>)}{message && <p role="alert">{message}</p>}
  </section>;
}
