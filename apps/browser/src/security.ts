export function webOrigin(value: string): string {
  const url = new URL(value);
  if (
    !["https:", "http:"].includes(url.protocol) ||
    url.username ||
    url.password
  )
    throw new Error("invalid-origin");
  return url.origin;
}
export function trustedUI(sender: chrome.runtime.MessageSender): boolean {
  if (
    sender.id !== chrome.runtime.id ||
    !sender.url ||
    (sender.tab?.url && !sender.url.startsWith(chrome.runtime.getURL("")))
  )
    return false;
  return ["popup.html", "index.html"].some(
    (path) => sender.url!.split("?")[0] === chrome.runtime.getURL(path),
  );
}

export function reminderPattern(origin: string): string {
  const url = new URL(webOrigin(origin));
  // Match patterns grant a hostname across ports; the worker separately checks the exact origin.
  return `${url.protocol}//${url.hostname}/*`;
}
