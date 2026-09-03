// The Flutter popup calls these helpers through its existing JS interop API.
window.hasChromeApi = () => Boolean(globalThis.chrome?.runtime?.id);
window.chromeSendMessage = (message) => new Promise((resolve) => {
  if (!window.hasChromeApi()) return resolve(null);
  chrome.runtime.sendMessage(message, (response) => {
    resolve(chrome.runtime.lastError ? null : response ?? null);
  });
});
window.chromeStorageGet = (key) => new Promise((resolve) => {
  chrome.storage.local.get([key], (result) => {
    resolve(chrome.runtime.lastError ? null : result[key] ?? null);
  });
});
window.chromeStorageSet = (key, value) => new Promise((resolve, reject) => {
  chrome.storage.local.set({ [key]: value }, () => {
    const error = chrome.runtime.lastError;
    if (error) reject(new Error(error.message));
    else resolve(null);
  });
});
window.chromeStorageRemove = (key) => new Promise((resolve, reject) => {
  chrome.storage.local.remove([key], () => {
    const error = chrome.runtime.lastError;
    if (error) reject(new Error(error.message));
    else resolve(null);
  });
});
