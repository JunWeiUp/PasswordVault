// Isolated world: page messages contain public ceremony options only.
(() => {
  if (window !== top || location.protocol !== "https:") return;
  const active = new Set<string>();
  /** Conditional (autofill) request waiting for the user to pick "use a passkey" in the inline menu. */
  let waiting: {id:string;options:unknown;href:string}|undefined;
  chrome.runtime.onMessage.addListener((request,sender,respond)=>{
    if(sender.id===chrome.runtime.id && request.action==="passkey-document-check") respond({ok:!document.hidden});
  });
  window.addEventListener("pagehide",()=>{waiting=undefined;void chrome.runtime.sendMessage({action:"passkey-cancel"});});
  async function run(id:string,operation:string,options:unknown):Promise<{ok:boolean;error?:string}> {
    active.add(id);
    const href=location.href;
    try {
      const result = await chrome.runtime.sendMessage({action:"passkey-request",operation,options});
      if (href === location.href && !document.hidden) window.postMessage({channel:"pv-passkey-response",id,result},location.origin);
      return result ?? {ok:false,error:"failed"};
    } finally { active.delete(id); }
  }
  // Shared with inline-fields.js (same extension isolated world). Never reachable by the page.
  (globalThis as any).pvConditionalPasskey = {
    available: () => !!waiting && waiting.href === location.href && active.size === 0,
    start: async (): Promise<{ok:boolean;error?:string}> => {
      const current = waiting;
      if (!current || current.href !== location.href || active.size) return {ok:false,error:"expired"};
      const result = await run(current.id,"get",current.options);
      // Success ends the conditional request; otherwise it stays available for another attempt.
      if (result.ok && waiting === current) waiting = undefined;
      return result;
    },
  };
  window.addEventListener("message", async (event) => {
    if(event.source===window && event.origin===location.origin && event.data?.channel==="pv-passkey-cancel") {
      if (waiting?.id === event.data.id) waiting = undefined;
      void chrome.runtime.sendMessage({action:"passkey-cancel"}); return;
    }
    if (event.source !== window || event.origin !== location.origin || event.data?.channel !== "pv-passkey-request") return;
    const {id,operation,options,conditional} = event.data;
    if (typeof id !== "string" || id.length > 100 || !["create","get"].includes(operation)) return;
    if (conditional === true) {
      if (operation === "get") waiting = {id,options,href:location.href};
      return;
    }
    if (active.has(id) || active.size >= 1) return;
    await run(id,operation,options);
  });
})();
