// Two-factor codes shown on accounts: an embedded secret, or a linked entry from 验证码.
import { View } from "nsh";
import { Menu } from "nsh/desktop";
import { Btn, Row, T, copySecret } from "../kit";
import { Icon } from "../icons";
import { call, dest, edit, errorText, go, items, itemsById, select, toast, type Item } from "../store";
import { c, MONO, fs } from "../theme";
import { formatCode, secondsLeft, TotpText } from "../totp";
import { hostOf, validPeriod, websites } from "./model";

export type AccountCode = { secret: string; period: number; source: "embedded" | "entry"; entry?: Item };
const periodOf = (item: Item) => (validPeriod(item.period ?? 30) ? Number(item.period ?? 30) : 30);
const live = (item: Item | undefined) => !!item && item.type === "totp" && !item.isDeleted && !!item.secret;

/** The code an account shows: its own secret first, then the linked 验证码 entry (`linkedTotpId`). */
export function codeFor(item: Item, list?: Item[]): AccountCode | null {
  if (item.type !== "password") return null;
  if (item.secret) return { secret: item.secret, period: periodOf(item), source: "embedded" };
  if (!item.linkedTotpId) return null;
  // O(1) Map lookup on the default live store list, eliminating O(N^2) scans across rows.
  const entry = list ? list.find(other => other.id === item.linkedTotpId) : itemsById().get(item.linkedTotpId);
  return live(entry) ? { secret: entry!.secret, period: periodOf(entry!), source: "entry", entry } : null;
}

/** Site labels used for matching, e.g. "accounts.google.com" → "google". Too-short labels are ignored. */
function siteLabels(item: Item): string[] {
  return [...new Set(websites(item.url ?? "").map(hostOf).map(host => host.split(".").slice(-2)[0] ?? "").filter(label => label.length >= 3))];
}
/** Code entries not linked by another account whose issuer/title names one of this account's sites. */
export function codeCandidates(item: Item, list: Item[] = items()): Item[] {
  const taken = new Set(list.filter(other => other.type === "password" && !other.isDeleted && other.id !== item.id && other.linkedTotpId).map(other => other.linkedTotpId));
  const labels = siteLabels(item);
  return list.filter(entry => live(entry) && !taken.has(entry.id) && labels.some(label => `${entry.issuer ?? ""} ${entry.title ?? ""}`.toLowerCase().includes(label)));
}
/** One suggestion, never applied automatically; the same username wins ties. Dismissed per code entry. */
export function suggestCode(item: Item, list: Item[] = items()): Item | null {
  if (item.type !== "password" || item.isDeleted || codeFor(item, list)) return null;
  const candidates = codeCandidates(item, list).filter(entry => entry.id !== item.totpSuggestionDismissed);
  const user = (item.username ?? "").trim().toLowerCase();
  return candidates.find(entry => user && (entry.username ?? "").trim().toLowerCase() === user) ?? candidates[0] ?? null;
}
/** Accounts that link to a code entry, shown on the code's own detail. */
export const linkedAccounts = (entry: Item, list: Item[] = items()) => list.filter(item => item.type === "password" && !item.isDeleted && item.linkedTotpId === entry.id);

export async function copyAccountCode(item: Item) {
  const code = codeFor(item);
  if (!code) return;
  try {
    const result = await call<{ code: string }>({ op: "totp", secret: code.secret, period: code.period, time: Math.floor(Date.now() / 1000) });
    await copySecret(result.code, `${item.title || "账号"}的验证码`);
  } catch (e) { toast(errorText(e)); }
}
export const linkCode = (item: Item, entry: Item) => { edit(item.id, d => { d.linkedTotpId = entry.id; delete d.totpSuggestionDismissed; }); toast(`已关联验证码「${entry.title || entry.issuer || "验证码"}」`); };
export const unlinkCode = (item: Item) => { edit(item.id, d => { delete d.linkedTotpId; }); toast("已取消关联，验证码条目保留"); };
export const dismissSuggestion = (item: Item, entry: Item) => edit(item.id, d => { d.totpSuggestionDismissed = entry.id; });
export function pickCodeMenu(item: Item, position?: { x: number; y: number }) {
  const taken = new Set(items().filter(other => other.type === "password" && other.id !== item.id && other.linkedTotpId).map(other => other.linkedTotpId));
  const free = items().filter(entry => live(entry) && !taken.has(entry.id));
  const preferred = new Set(codeCandidates(item).map(entry => entry.id));
  const sorted = [...free.filter(entry => preferred.has(entry.id)), ...free.filter(entry => !preferred.has(entry.id))].slice(0, 40);
  if (!sorted.length) { toast("没有可关联的验证码"); return; }
  void Menu.popup(sorted.map(entry => ({ label: `${entry.title || entry.issuer || "验证码"}${entry.username ? ` · ${entry.username}` : ""}`, onSelect: () => linkCode(item, entry) })), position);
}
export function openCodeEntry(entry: Item) { go("codes"); select(entry.id); }

/** Compact live code for list rows; pressing copies without selecting the row. */
export function RowCode(props: { item: Item; active?: boolean }) {
  const code = () => codeFor(props.item);
  const liveTick = () => props.active !== false;
  return <If when={code() && dest() !== "trash"}>
    <View role="button" accessibilityLabel={`复制 ${props.item.title || "账号"} 的验证码`} tooltip="点击复制验证码"
      onPress={() => void copyAccountCode(props.item)}
      style={{ alignItems: "flex-end", gap: 3, paddingHorizontal: 5, paddingVertical: 3, borderRadius: 6, cursor: "copy" }}
      hoverStyle={{ backgroundColor: c().blueSoft }}>
      <TotpText secret={code()!.secret} period={code()!.period} active={liveTick()} style={{ fontFamily: MONO, fontSize: fs(12), fontWeight: "600", color: c().blue }} />
      <T size={11} color={c().faint}>{liveTick() ? `${secondsLeft(code()!.period)}s` : "—"}</T>
    </View>
  </If>;
}

/** The 验证码 row inside an account's 登录信息. */
export function AccountCodeRow(props: { item: Item; editing: boolean; onAddSecret: () => void }) {
  const code = () => codeFor(props.item);
  const suggestion = () => suggestCode(props.item);
  const label = <T size={12} color={c().muted} style={{ width: 96 }}>验证码</T>;
  const row = (children: any) => <Row gap={14} style={{ paddingVertical: 10, minHeight: 46, borderBottomWidth: 1, borderBottomColor: c().line2 }}>{label}{children}</Row>;
  return <If when={code()} else={
    <If when={suggestion()} else={<If when={props.editing}>{row(<Row gap={8} wrap style={{ flex: 1 }}>
      <Btn label="扫描二维码或输入密钥" icon="qr" onPress={props.onAddSecret} />
      <Btn label="关联已有验证码…" icon="link" onPress={() => pickCodeMenu(props.item)} />
    </Row>)}</If>}>
      {row(<>
        <Row gap={8} style={{ flex: 1, minWidth: 0 }}><Icon name="clock" size={14} tint={c().muted} /><T size={12.5} color={c().ink2} lines={1} style={{ flexShrink: 1 }}>找到可能匹配的验证码「{suggestion()?.title || suggestion()?.issuer}{suggestion()?.username ? ` · ${suggestion()?.username}` : ""}」</T></Row>
        <Btn label="关联" kind="primary" onPress={() => linkCode(props.item, suggestion()!)} />
        <Btn label="忽略" kind="ghost" onPress={() => dismissSuggestion(props.item, suggestion()!)} />
      </>)}
    </If>
  }>
    {row(<>
      <Row gap={10} style={{ flex: 1, minWidth: 0 }}>
        <TotpText secret={code()!.secret} period={code()!.period} style={{ fontFamily: MONO, fontSize: fs(20), fontWeight: "600", color: secondsLeft(code()!.period) <= 5 ? c().orange : c().ink }} />
        <T size={11.5} color={c().muted}>{secondsLeft(code()!.period)}s</T>
        <T size={11.5} color={c().faint} lines={1} style={{ flexShrink: 1 }}>{code()!.source === "entry" ? `来自验证码「${code()!.entry?.title || code()!.entry?.issuer || ""}」` : "账号内置密钥"}</T>
      </Row>
      <Btn label="复制" icon="copy" kind="ghost" onPress={() => void copyAccountCode(props.item)} />
      <If when={code()!.source === "entry"}><Btn label="打开" kind="ghost" onPress={() => openCodeEntry(code()!.entry!)} /></If>
      <If when={props.editing && code()!.source === "entry"}><Btn label="取消关联" kind="danger" onPress={() => unlinkCode(props.item)} /></If>
    </>)}
  </If>;
}
