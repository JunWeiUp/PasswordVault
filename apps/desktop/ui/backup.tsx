// Password sheets keep server credentials separate from archive passphrases.
import { signal, View } from "nsh";
import { Backup, Files, Platform } from "passwordvault/native";
import { Banner, Btn, openSheet, SheetFooter, SheetTitle, T, TextBox } from "./kit";
import { errorText, flush, load, phase, toast, vaultInstance } from "./store";
import { c } from "./theme";

export function backupError(e: unknown) {
  const key=String(e).replace(/^Error:\s*/, "");
  const messages:Record<string,string>={AlreadyExists:"该文件名已存在，请选择新的文件名。",WebDAVNetwork:"连接失败，请检查服务器地址和网络后重试。",WebDAVAuthentication:"WebDAV 用户名或登录密码不正确。",WebDAVPermission:"服务器拒绝访问，请检查目录权限。",WebDAVNotFound:"服务器上找不到目录或备份文件。",WebDAVRedirectRejected:"服务器返回重定向，已拒绝连接。请填写最终 HTTPS 地址。",WebDAVServer:"服务器未能完成请求，请稍后重试。"};
  return messages[key] ?? errorText(e);
}
export async function flushBackup() {
  if (!(await flush())) throw new Error("请先解决未保存的编辑，再重试。");
  if (phase() !== "unlocked") throw new Error("Locked");
}
export function passwordSheet(title: string, text: string, create: boolean, action: (password: string) => Promise<void>) {
  const first = signal(""); const second = signal(""); const busy = signal(false); const error = signal("");
  const valid = () => !create || (first().length >= 10 && first() === second());
  openSheet({ render: close => {
    const cancel = () => { first.set(""); second.set(""); close(); };
    const run = async () => {
      if (busy() || !valid()) return;
      busy.set(true); error.set("");
      try { await flushBackup(); await action(first()); cancel(); }
      catch (e) { error.set(String(e).includes("Authentication") ? "无法解密，请核对这份备份的密码；旧版备份使用当时的主密码。文件损坏也可能导致此错误。" : backupError(e)); }
      finally { busy.set(false); }
    };
    return <View style={{ gap: 10 }}>
      <SheetTitle title={title} text={text} />
      <TextBox value={first()} onChange={v => first.set(v)} masked autoFocus placeholder="这份备份的密码" testID="backup-password" />
      {create && <TextBox value={second()} onChange={v => second.set(v)} masked placeholder="确认备份密码（至少 10 个字符）" testID="backup-confirm" />}
      <Banner tone="warn" title={create ? "单独保管备份密码" : "合并到当前密码库"}>{create ? "备份包含完整资料、附件和设置；忘记备份密码将无法打开文件。" : "同一记录保留较新版本，包含回收站状态；当前独有记录保留。"}</Banner>
      <T color={c().red}>{error()}</T>
      <SheetFooter><Btn label="取消" disabled={busy()} onPress={cancel} /><Btn label={busy() ? "处理中…" : create ? "创建备份" : "恢复并合并"} kind="primary" disabled={busy() || !valid()} onPress={run} /></SheetFooter>
    </View>;
  }});
}
export function exportBackup() {
  passwordSheet("导出加密备份", "选择保存位置。已有备份不会被覆盖，请使用新的文件名。", true, async password => {
    const path = await Files.pickSave("导出加密备份", `PasswordVault-${Date.now()}.pvbackup`, ["pvbackup"]);
    if (!path) return;
    await flushBackup();
    await Backup.exportFile(vaultInstance, path, password);
    toast("已导出加密备份"); Platform.reveal(path);
  });
}
export async function importBackup() {
  try {
    const path = await Files.pickOpen("从备份恢复", ["pvbackup", "json", "bak"]);
    if (!path || phase() !== "unlocked") return;
    passwordSheet("从备份恢复", path.split("/").pop() ?? "", false, async password => {
      const result = JSON.parse(await Backup.importFile(vaultInstance, path, password));
      if (phase() !== "unlocked") return;
      await load(); toast(`合并完成：新增或更新 ${result.imported ?? 0} 条记录`);
    });
  } catch(e) { toast(errorText(e)); }
}
