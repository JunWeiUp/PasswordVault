// Sandboxed editor: receives only explicit messages from its owning UI frame.
const channel = location.hash.slice(1);
const resources = new Map();
const send = (message) => parent.postMessage({ ...message, channel }, "*");
window.pvResourceURL = (id) => resources.get(id) || "";
window.webkit = { messageHandlers: { noteEditor: { postMessage: send } } };
addEventListener("message", async (event) => {
  if (event.source !== parent || event.data?.channel !== channel) return;
  const { method, args = [] } = event.data;
  if (method === "resource") {
    const [id, data, mime] = args;
    if (typeof data !== "string" || data.length > 36 * 1024 * 1024) return;
    const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
    if (resources.has(id)) URL.revokeObjectURL(resources.get(id));
    resources.set(id, URL.createObjectURL(new Blob([bytes], { type: mime })));
    for (const node of document.querySelectorAll("[data-vault-image]")) {
      if (node.getAttribute("attachmentid") === id)
        node.querySelector("img")?.setAttribute("src", resources.get(id));
    }
  } else if (
    [
      "configure",
      "attachment",
      "uploadError",
      "uploadProgress",
      "snapshot",
    ].includes(method)
  ) {
    if (method === "configure") {
      const theme = args[0]?.theme;
      document.documentElement.style.colorScheme =
        theme === "dark" ? "dark" : theme === "light" ? "light" : "light dark";
    }
    const result = await window.pvEditor?.[method](...args);
    if (method === "snapshot")
      send({ kind: "snapshot", result, request: args[1] });
  }
});

// A sandboxed iframe's trusted input events do not bubble to the application document.
for (const kind of ["pointerdown", "keydown"])
  addEventListener(kind, (event) => {
    if (event.isTrusted) send({ kind: "activity" });
  });
