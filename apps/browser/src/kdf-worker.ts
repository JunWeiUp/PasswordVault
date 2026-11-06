import init, { bootstrapCreate, bootstrapUnlock, bootstrapRecover, bootstrapRestoreRecovery } from "../wasm/vault_core";
self.onmessage = async (
  event: MessageEvent<{ create: boolean; password: string; storage?: string; recoveryKey?:string; newPassword?:string; content?:string; recover?:boolean }>,
) => {
  try {
    await init();
    const { create, password, storage } = event.data;
    if (event.data.recover) {
      const result = JSON.parse(event.data.content === undefined
        ? bootstrapRecover(storage!, event.data.recoveryKey!, event.data.newPassword!)
        : bootstrapRestoreRecovery(event.data.content, event.data.recoveryKey!, event.data.newPassword!));
      const key = Uint8Array.from(atob(result.key), c => c.charCodeAt(0));
      self.postMessage({storage:result.storage,key},[key.buffer]);
    } else if (create) {
      const result = JSON.parse(bootstrapCreate(password));
      const key = Uint8Array.from(atob(result.key), (c) => c.charCodeAt(0));
      self.postMessage({ storage: result.storage, key }, [key.buffer]);
    } else {
      const key = bootstrapUnlock(storage!, password);
      self.postMessage({ storage, key }, [key.buffer]);
    }
  } catch {
    self.postMessage({ error: "authentication" });
  } finally {
    event.data.password = "";
    event.data.recoveryKey = ""; event.data.newPassword = ""; event.data.content = "";
  }
};
