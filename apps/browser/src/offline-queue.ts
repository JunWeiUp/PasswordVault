// Device-local staging only, not a master-password-protected vault. The browser
// stores a non-extractable key; profile access/extension compromise is out of scope.
export type QueuedLogin = {
  origin: string;
  username: string;
  password: string;
};
type Envelope = {
  id: string;
  iv: Uint8Array<ArrayBuffer>;
  ciphertext: ArrayBuffer;
};
const DB = "PasswordVaultOfflineQueueV1";
async function database(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => {
      r.result.createObjectStore("key");
      r.result.createObjectStore("queue", { keyPath: "id" });
    };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(new Error("storage"));
  });
}
async function transaction<T>(
  store: string,
  write: boolean,
  work: (s: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  const db = await database();
  try {
    return await new Promise<T>((resolve, reject) => {
      const tx = db.transaction(store, write ? "readwrite" : "readonly");
      const r = work(tx.objectStore(store));
      tx.oncomplete = () => resolve(r.result);
      tx.onabort = tx.onerror = () => reject(new Error("storage"));
    });
  } finally {
    db.close();
  }
}
async function key(): Promise<CryptoKey> {
  const existing = await transaction("key", false, (s) => s.get("aes"));
  if (existing) return existing;
  const generated = await crypto.subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
  // add, never put: another context must not replace the key of queued records.
  try {
    await transaction("key", true, (s) => s.add(generated, "aes"));
  } catch {
    const raced = await transaction("key", false, (s) => s.get("aes"));
    if (!raced) throw new Error("storage");
    return raced;
  }
  return generated;
}
export async function queuedCount(): Promise<number> {
  return transaction("queue", false, (s) => s.count());
}
export async function enqueue(login: QueuedLogin): Promise<void> {
  if ((await queuedCount()) >= 500) throw new Error("offline-full");
  const id = crypto.randomUUID(),
    iv = crypto.getRandomValues(new Uint8Array(12));
  const bytes = new TextEncoder().encode(JSON.stringify(login));
  try {
    const ciphertext = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(id) },
      await key(),
      bytes,
    );
    await transaction("queue", true, (s) => s.add({ id, iv, ciphertext }));
  } finally {
    bytes.fill(0);
  }
}
export async function syncQueue(
  deliver: (login: QueuedLogin, id: string) => Promise<void>,
): Promise<void> {
  const records: Envelope[] = await transaction("queue", false, (s) =>
    s.getAll(),
  );
  if (!records.length) return;
  const secret = await key();
  for (const record of records) {
    const bytes = new Uint8Array(
      await crypto.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: record.iv,
          additionalData: new TextEncoder().encode(record.id),
        },
        secret,
        record.ciphertext,
      ),
    );
    const login: QueuedLogin = JSON.parse(new TextDecoder().decode(bytes));
    bytes.fill(0);
    try {
      await deliver(login, record.id);
      await transaction("queue", true, (s) => s.delete(record.id));
    } finally {
      login.username = "";
      login.password = "";
    }
  }
}
