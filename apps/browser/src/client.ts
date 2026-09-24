import { readStorage } from "./storage";
import type { Request } from "./core";
export const isExtension =
  typeof chrome !== "undefined" && !!chrome.runtime?.id;
export async function message(request: Record<string, unknown>): Promise<any> {
  if (!isExtension) throw new Error("extension-only");
  const result = await chrome.runtime.sendMessage(request);
  if (!result?.ok) throw new Error(result?.error ?? "unavailable");
  return result.data;
}
export async function status() {
  if (isExtension) return message({ action: "status" });
  const core = await import("./core");
  return {
    mode: "independent",
    exists: !!(await readStorage()),
    unlocked: !core.locked(),
  };
}
export async function authenticate(password: string, create: boolean) {
  const storage = await readStorage();
  if (create && storage) throw new Error("already-exists");
  if (!create && !storage) throw new Error("missing");
  const worker = new Worker(new URL("./kdf-worker.ts", import.meta.url), {
    type: "module",
  });
  try {
    const output = await new Promise<{ storage: string; key: Uint8Array }>(
      (resolve, reject) => {
        worker.onmessage = (e) =>
          e.data.error ? reject(new Error("authentication")) : resolve(e.data);
        worker.onerror = () => reject(new Error("authentication"));
        worker.postMessage({ password, storage, create });
      },
    );
    try {
      if (isExtension)
        await message({
          action: "unlock",
          storage: output.storage,
          key: Array.from(output.key),
          create,
        });
      else {
        const core = await import("./core");
        await core.unlock(output.storage, output.key, create);
      }
    } finally {
      output.key.fill(0);
    }
  } finally {
    worker.terminate();
    password = "";
  }
}
export async function command(request: Request): Promise<any> {
  if (isExtension) return message({ action: "command", request });
  const core = await import("./core");
  return core.command(request);
}
export async function lock() {
  if (isExtension) await message({ action: "lock" });
  else {
    const core = await import("./core");
    core.lock();
  }
}
export function errorText(error: unknown) {
  const code = error instanceof Error ? error.message : String(error);
  return (
    (
      {
        "invalid-entry": "该账号已变更或不属于当前网站，请刷新后重试。",
        unsupported: "请更新 Mac 应用后重试。",
        locked: "资料库已锁定，请重新解锁。",
        "site-permission": "未获得此网站的访问权限，仍可手动读取并保存账号。",
        authentication: "密码不正确，或文件已损坏。",
        unpaired: "请先在 Mac 上确认连接。",
        "pairing-busy": "另一浏览器正在配对，请完成或取消该请求后重试。",
        "pairing-limit":
          "浏览器连接已达到上限，请在 Mac 设置中清理连接后重试。",
        "native-host-missing":
          "尚未登记浏览器连接，请到 Mac 的设置 → 浏览器中登记。",
        "native-host-forbidden":
          "当前插件未获连接权限，请使用配套插件并在 Mac 上重新登记。",
        "native-unavailable":
          "Mac 连接未完成，请检查应用是否打开，并重新检测连接。",
        cancelled: "已取消连接，可以重新发起。",
        "invalid-origin": "此页面不支持填充，请切换到普通网站的登录页面。",
        "changed-origin": "网页已跳转，请重新打开插件再操作。",
        fill: "没有找到可填写的密码框，请打开网站的登录表单。",
        capture: "没有找到可保存的登录表单，请先填写网站账号和密码。",
        "not-running": "请打开 Mac 应用，并在设置中登记浏览器连接。",
        "stale-storage": "资料库已在另一页面更新，请重新解锁。",
        "already-exists": "已有资料库，不能覆盖创建。",
      } as Record<string, string>
    )[code] ?? "操作未完成，请检查连接、密码或存储权限后重试。"
  );
}
