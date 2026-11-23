// Passkey ceremony prompt for the browser bridge. Shows public metadata only;
// the master password goes straight to the bridge, which reauthenticates it in the core.
import { signal, View } from "nsh";
import { Banner, Btn, ListRow, openSheet, SheetFooter, SheetTitle, T, TextBox } from "../kit";
import { c } from "../theme";

export type PasskeyMatch = { library: string; itemId: string; id: string; userName?: string };
export type PasskeyPrompt = {
  challenge: string;
  passkey: { operation: "create" | "get"; origin: string; rpId: string; userName?: string; matches: PasskeyMatch[] };
};
export type PasskeySelection = { currentPassword?: string; credentialId?: string; itemId?: string; library?: string; fallback?: true };

/** Opens the confirmation sheet; exactly one of `onApprove`/`onCancel` runs. */
export function openPasskeyPrompt(prompt: PasskeyPrompt, onApprove: (selection: PasskeySelection) => void, onCancel: () => void) {
  const p = prompt.passkey;
  const create = p.operation === "create";
  const chosen = signal<PasskeyMatch | null>(create || p.matches.length !== 1 ? null : p.matches[0]);
  const password = signal("");
  let answered = false;
  const finish = (close: () => void, approve: boolean) => {
    if (answered) return;
    if (approve && (!password() || (!create && !chosen()))) return;
    answered = true;
    const secret = password();
    password.set("");
    close();
    if (!approve) { onCancel(); return; }
    const pick = chosen();
    onApprove(create ? { currentPassword: secret } : { currentPassword: secret, credentialId: pick!.id, itemId: pick!.itemId, library: pick!.library });
  };
  openSheet({
    width: 460,
    render: (close) => <View style={{ gap: 10 }}>
      <SheetTitle title={create ? "为此网站创建通行密钥？" : "使用通行密钥登录？"}
        text={`${p.origin}\n${create ? `将为账号「${p.userName || "未命名"}」创建新的通行密钥，保存到个人资料库。` : "网站将收到签名，不会收到私钥或主密码。"}请求将在 50 秒后失效。`} />
      <If when={!create}>
        <View style={{ gap: 6 }}>
          <Each of={p.matches}>{(m) => <ListRow icon="passkey" title={m().userName || "未命名账号"}
            note={`${p.rpId}${m().library ? " · 共享资料库" : ""}${chosen()?.id === m().id && chosen()?.itemId === m().itemId ? " · 已选择" : ""}`}
            onPress={() => chosen.set(m())} />}</Each>
        </View>
      </If>
      <If when={!create && !chosen()}><T size={12} color={c().muted}>请选择一个通行密钥。</T></If>
      <TextBox testID="passkey-password" label="当前主密码" placeholder="输入主密码以确认" masked autoFocus value={password()}
        onChange={(v) => password.set(v)} onSubmit={() => finish(close, true)} />
      <Banner tone="info" title="每次使用都需要主密码">通行密钥私钥只保存在加密资料库中。</Banner>
      <SheetFooter left={<Btn kind="ghost" label="改用其他设备" onPress={() => { if (answered) return; answered = true; password.set(""); close(); onApprove({ fallback: true }); }} />}>
        <Btn label="取消" onPress={() => finish(close, false)} />
        <Btn testID="passkey-approve" kind="primary" label={create ? "创建通行密钥" : "登录"} disabled={!password() || (!create && !chosen())} onPress={() => finish(close, true)} />
      </SheetFooter>
    </View>,
  });
}
