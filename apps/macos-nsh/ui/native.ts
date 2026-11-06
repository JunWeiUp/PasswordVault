// Bind the store's one Vault instance; never create a second native session.
import { Platform, Vault } from "passwordvault/native";
let bound: Vault | undefined;
export function bindNativeVault(vault: Vault): void { bound = vault; }
function vault(): Vault {
  if (!bound) throw new Error("NativeVaultNotBound");
  return bound;
}
export function biometricAvailability(): boolean { return Vault.biometricAvailable(); }
export function biometricEnabled(): boolean { return vault().biometricEnabled(); }
export function enableBiometrics(password: string): Promise<void> { return vault().biometricEnable(password); }
export function disableBiometrics(): Promise<void> { return vault().biometricDisable(); }
export function unlockWithBiometrics(): Promise<void> { return vault().unlockWithBiometrics(); }
export type LockSignals = { events: number; idleSeconds: number | null };
// Bits: sleep=1, session resign=2, screen lock=4, screensaver=8.
// One app-level subscriber should drain this process-wide notification queue.
export function pollLockSignals(): LockSignals { return JSON.parse(Platform.pollLockSignals()); }
export function onLockSignals(listener: (signals: LockSignals) => void): () => void {
  listener(pollLockSignals());
  const timer = setInterval(() => listener(pollLockSignals()), 500);
  return () => clearInterval(timer);
}
export function biometricError(error: unknown): string {
  const message = String(error);
  if (message.includes("-34018")) return "当前预览包缺少钥匙串签名权限，请使用配置权限的签名版本。";
  if (message.includes("-128")) return "已取消 Touch ID，可继续使用主密码。";
  if (message.includes("-25300")) return "Touch ID 凭据已失效，请用主密码解锁后重新启用。";
  if (message.includes("BiometricUnavailable")) return "Touch ID 暂不可用，请检查系统指纹设置。";
  return "Touch ID 操作未完成，请重试或使用主密码。";
}
