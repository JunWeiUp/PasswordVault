export type NativeState = {
  available?: boolean;
  unlocked?: boolean;
  paired?: boolean;
  connectionError?: string;
};

// Browser-generated diagnostics may contain local paths. Expose only stable codes.
export function nativeTransportError(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error);
  if (/host.*not found|native messaging host.*not.*found/i.test(text))
    return "native-host-missing";
  if (/forbidden|not allowed|access.*denied/i.test(text))
    return "native-host-forbidden";
  return "native-unavailable";
}

export function connectionPresentation(state: NativeState) {
  if (state.available === false) {
    const needsRegistration = [
      "native-host-missing",
      "native-host-forbidden",
    ].includes(state.connectionError ?? "");
    return {
      title: needsRegistration ? "先登记浏览器连接" : "尚未连接到 Mac",
      message: needsRegistration
        ? "在 Mac 应用的「设置 → 浏览器」中登记连接，支持 Chrome、Edge 和 Edge Beta。"
        : "请打开 PasswordVault。若应用已打开，请重新登记连接后再检测。",
      canOpen: !needsRegistration,
      canPair: false,
    };
  }
  if (!state.unlocked)
    return {
      title: "在 Mac 上解锁",
      message: "已找到 Mac 应用。使用主密码或 Touch ID 解锁后即可继续。",
      canOpen: true,
      canPair: false,
    };
  if (!state.paired)
    return {
      title: "连接这台 Mac",
      message: "点击发起连接，然后在 Mac 弹窗中选择「允许连接」。",
      canOpen: true,
      canPair: true,
    };
  return {
    title: "已连接 Mac",
    message: "账号保存在 Mac 上。锁定 Mac 资料库后，插件也会停止读取。",
    canOpen: true,
    canPair: false,
  };
}
