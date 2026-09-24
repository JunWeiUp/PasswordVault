import init, { bootstrapCreate, bootstrapUnlock } from "../wasm/vault_core";
self.onmessage = async (
  event: MessageEvent<{ create: boolean; password: string; storage?: string }>,
) => {
  try {
    await init();
    const { create, password, storage } = event.data;
    if (create) {
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
  }
};
