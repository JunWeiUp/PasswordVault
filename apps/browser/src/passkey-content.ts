// Isolated world: page messages contain public ceremony options only.
(() => {
  if (window !== top || location.protocol !== "https:") return;
  const active = new Set<string>();
  chrome.runtime.onMessage.addListener((request,sender,respond)=>{
    if(sender.id===chrome.runtime.id && request.action==="passkey-document-check") respond({ok:!document.hidden});
  });
  window.addEventListener("pagehide",()=>void chrome.runtime.sendMessage({action:"passkey-cancel"}));
  window.addEventListener("message", async (event) => {
    if(event.source===window && event.origin===location.origin && event.data?.channel==="pv-passkey-cancel") {
      void chrome.runtime.sendMessage({action:"passkey-cancel"}); return;
    }
    if (event.source !== window || event.origin !== location.origin || event.data?.channel !== "pv-passkey-request") return;
    const {id,operation,options} = event.data;
    if (typeof id !== "string" || id.length > 100 || !["create","get"].includes(operation) || active.has(id) || active.size >= 1) return;
    active.add(id);
    const href=location.href;
    try {
      const result = await chrome.runtime.sendMessage({action:"passkey-request",operation,options});
      if (href === location.href && !document.hidden) window.postMessage({channel:"pv-passkey-response",id,result},location.origin);
    } finally { active.delete(id); }
  });
})();
