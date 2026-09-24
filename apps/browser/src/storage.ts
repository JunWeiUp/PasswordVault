// Only the authenticated encrypted bundle goes into IndexedDB; never a key or a record.
const DATABASE = "PasswordVaultNativeV2";
function openDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () =>
      request.result.createObjectStore("encrypted");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error("storage"));
  });
}
export async function readStorage(): Promise<string | undefined> {
  const db = await openDB();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction("encrypted");
      const r = tx.objectStore("encrypted").get("vault");
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(new Error("storage"));
    });
  } finally {
    db.close();
  }
}
export async function writeStorage(
  value: string,
  expected: string | undefined,
): Promise<void> {
  const db = await openDB();
  try {
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction("encrypted", "readwrite");
      const store = tx.objectStore("encrypted");
      const previous = store.get("vault");
      previous.onsuccess = () => {
        if (previous.result !== expected) {
          tx.abort();
          return;
        }
        store.put(value, "vault");
      };
      tx.oncomplete = () => resolve();
      tx.onabort = tx.onerror = () => reject(new Error("storage"));
    });
  } finally {
    db.close();
  }
}
