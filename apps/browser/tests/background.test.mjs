import test from "node:test";
import assert from "node:assert/strict";
const extension = "imoadebbgajpakiddkjpfgapbadkedop";
let listener;
let idleInterval;
let idleChanged;
let fetches = 0;
let getTabHook;
let tabURL = "https://example.com/login";
let permissionGranted = true;
let tabUpdated;
let permissionAdded;
const session = {};
let duplicate = false;
const scripts = new Map();
const badges = [];
let accountCount = 1;
const createdTabs = [];
const nativeCalls = [];
const pageCalls = [];
let nativeFailure;
let nativeStatus = { ok: true, unlocked: true, paired: true };
let operationFailure;
const stored = { token: "Synthetic pairing capability" };
const ui = { id: extension, url: `chrome-extension://${extension}/popup.html` };
globalThis.fetch = () => {
  fetches++;
  throw new Error("Native mode must not fetch WASM");
};
globalThis.chrome = {
  runtime: {
    id: extension,
    getURL: (path) => `chrome-extension://${extension}/${path}`,
    onMessage: { addListener: (fn) => (listener = fn) },
    onInstalled: { addListener: () => {} },
    sendNativeMessage: async (host, request) => {
      nativeCalls.push(request);
      if (nativeFailure) throw new Error(nativeFailure);
      if (request.op === "status") return nativeStatus;
      if (operationFailure) return { ok: false, error: operationFailure };
      if (request.op === "pair")
        return { ok: true, token: "New synthetic pairing capability" };
      if (request.op === "matches")
        return {
          ok: true,
          data: Array.from({ length: accountCount }, (_, i) => ({
            id: i ? `fixture-${i}` : "fixture",
            title: "Test",
            username: "fixture@example.com",
          })),
        };
      if (request.op === "fill")
        return {
          ok: true,
          data: {
            username: duplicate ? "fixture@example.com" : "fixture",
            password: "synthetic-only",
          },
        };
      return { ok: true, data: {} };
    },
  },
  storage: {
    session: {
      get: async (key) => ({ [key]: session[key] }),
      set: async (values) => Object.assign(session, values),
      remove: async (key) => {
        delete session[key];
      },
    },
    local: {
      get: async (key) => ({ [key]: stored[key] }),
      set: async (values) => Object.assign(stored, values),
      remove: async (key) => {
        delete stored[key];
      },
    },
  },
  tabs: {
    onActivated: { addListener: () => {} },
    create: async (data) => {
      createdTabs.push(data);
      return { id: 9, ...data };
    },
    onRemoved: { addListener: () => {} },
    onUpdated: { addListener: (fn) => (tabUpdated = fn) },
    query: async () => [{ id: 7, url: tabURL }],
    get: async (id) => { await getTabHook?.(); return { id, url: tabURL }; },
    sendMessage: async (...args) => {
      pageCalls.push(args);
      return { ok: true };
    },
  },
  scripting: {
    getRegisteredContentScripts: async ({ ids }) =>
      ids.filter((id) => scripts.has(id)).map((id) => scripts.get(id)),
    registerContentScripts: async (entries) =>
      entries.forEach((entry) => scripts.set(entry.id, entry)),
    unregisterContentScripts: async ({ ids }) =>
      ids.forEach((id) => scripts.delete(id)),
    executeScript: async (args) => {
      assert.equal(args.target.tabId, 7);
      assert.ok(["content.js", "login-observer.js"].includes(args.files[0]));
    },
  },
  permissions: {
    onAdded: { addListener: (fn) => (permissionAdded = fn) },
    contains: async () => permissionGranted,
    onRemoved: { addListener: () => {} },
  },
  action: {
    setTitle: async () => {},
    openPopup: async () => {
      throw new Error("No active window");
    },
    setBadgeText: async (value) => badges.push(value),
    setBadgeBackgroundColor: async () => {},
  },
  idle: {
    onStateChanged: { addListener: (fn) => (idleChanged = fn) },
    setDetectionInterval: (seconds) => {
      idleInterval = seconds;
    },
  },
};
await import("../dist/background.js");
const send = (request, sender = ui) =>
  new Promise((resolve) => listener(request, sender, resolve));
test("worker rejects page senders and unknown extension pages", async () => {
  assert.equal(
    (
      await send(
        { action: "status" },
        { id: extension, url: "https://example.com" },
      )
    ).error,
    "forbidden",
  );
  assert.equal(
    (await send({ action: "status" }, { id: "other", url: ui.url })).error,
    "forbidden",
  );
  assert.equal(
    (
      await send(
        { action: "status" },
        { ...ui, url: `chrome-extension://${extension}/unknown.html` },
      )
    ).error,
    "forbidden",
  );
  assert.equal(nativeCalls.length, 0);
});
test("native mode never loads WASM and resolves the website from browser-owned tab state", async () => {
  assert.equal((await send({ action: "status" })).data.unlocked, true);
  const matches = await send({
    action: "matches",
    origin: "https://attacker.test",
  });
  assert.equal(matches.data.origin, "https://example.com");
  assert.equal(nativeCalls.at(-1).origin, "https://example.com");
  assert.equal(fetches, 0);
  assert.equal(
    (await send({ action: "command", request: { op: "list" } })).error,
    "native-app",
  );
});
test("fill aborts on a stale page origin and only fills the top frame after an explicit action", async () => {
  const before = nativeCalls.length;
  assert.equal(
    (
      await send({
        action: "fill",
        tabId: 7,
        origin: "https://other.test",
        id: "fixture",
      })
    ).error,
    "changed-origin",
  );
  assert.equal(nativeCalls.length, before);
  assert.equal(pageCalls.length, 0);
  const result = await send({
    action: "fill",
    tabId: 7,
    origin: "https://example.com",
    id: "fixture",
  });
  assert.equal(result.ok, true);
  assert.equal(pageCalls.length, 1);
  assert.deepEqual(pageCalls[0][2], { frameId: 0 });
  assert.equal(pageCalls[0][1].origin, "https://example.com");
  assert.equal(fetches, 0);
});

test("missing registration is distinct from a locked Mac and retains no raw path diagnostics", async () => {
  nativeFailure = "Specified native messaging host not found. /private/example";
  const absent = (await send({ action: "status" })).data;
  assert.equal(absent.available, false);
  assert.equal(absent.connectionError, "native-host-missing");
  assert.equal(JSON.stringify(absent).includes("/private"), false);
  nativeFailure = "Access to the specified native messaging host is forbidden.";
  assert.equal(
    (await send({ action: "status" })).data.connectionError,
    "native-host-forbidden",
  );
  nativeFailure = undefined;
  nativeStatus = { ok: true, unlocked: false, paired: false };
  const locked = (await send({ action: "status" })).data;
  assert.equal(locked.available, true);
  assert.equal(locked.unlocked, false);
  assert.ok(stored.token, "Locking must not revoke a legitimate pairing");
});

test("revoked native authorization clears the stale capability and permits pairing again", async () => {
  nativeStatus = { ok: true, unlocked: true, paired: false };
  assert.equal((await send({ action: "status" })).data.paired, false);
  assert.equal(stored.token, undefined);
  assert.equal((await send({ action: "pair" })).ok, true);
  assert.equal(stored.token, "New synthetic pairing capability");
  nativeStatus = { ok: true, unlocked: true, paired: true };
  assert.equal((await send({ action: "status" })).data.paired, true);
  operationFailure = "unpaired";
  assert.equal((await send({ action: "matches" })).error, "unpaired");
  assert.equal(stored.token, undefined);
  operationFailure = undefined;
});

test("cancelled pairing never stores a token or writes a page credential", async () => {
  operationFailure = "cancelled";
  const before = pageCalls.length;
  assert.equal((await send({ action: "pair" })).error, "cancelled");
  assert.equal(stored.token, undefined);
  assert.equal(pageCalls.length, before);
  operationFailure = undefined;
  assert.equal(fetches, 0);
});

const page = {
  id: extension,
  url: "https://example.com/login",
  frameId: 0,
  tab: { id: 7, url: "https://example.com/login" },
};
const submitted = {
  action: "login-submitted",
  username: "fixture@example.com",
  password: "synthetic-only",
};
test("login detection is enabled by default and enforces frame identity and browser-owned origin", async () => {
  assert.equal((await send(submitted, page)).data.pending, true);
  await send({ action: "login-dismiss" }, page);
  assert.equal(
    (
      await send({
        action: "configure-reminder",
        origin: "https://example.com",
        tabId: 7,
        enabled: true,
      })
    ).ok,
    true,
  );
  for (const sender of [
    { ...page, id: "other" },
    { ...page, frameId: 1 },
    { ...page, url: "https://other.test" },
  ])
    assert.equal((await send(submitted, sender)).ok, false);
  permissionGranted = false;
  assert.equal((await send(submitted, page)).error, "forbidden");
  permissionGranted = true;
  assert.equal(
    (await send({ ...submitted, action: "save-captured" }, page)).ok,
    false,
  );
});

test("pending credentials stay ephemeral and are only exposed to the trusted popup", async () => {
  const result = await send(
    { ...submitted, origin: "https://attacker.test", tabId: 999 },
    page,
  );
  assert.equal(result.data.pending, true);
  assert.equal(JSON.stringify(result).includes(submitted.password), false);
  assert.equal(JSON.stringify(stored).includes(submitted.password), false);
  const pending = (await send({ action: "matches" })).data.pending;
  assert.equal(pending.origin, "https://example.com");
  assert.equal(pending.tabId, 7);
  assert.equal(pending.password, submitted.password);
  assert.deepEqual((await send({ action: "login-pending" }, page)).data, {
    enabled: true,
    pending: true,
    notice: {
      id: pending.id,
      origin: pending.origin,
      expires: pending.expires,
    },
  });
  assert.equal((await send({ action: "matches" }, page)).error, "forbidden");
  await send({
    action: "dismiss-pending",
    tabId: 7,
    origin: pending.origin,
    id: pending.id,
  });
  assert.equal((await send({ action: "matches" })).data.pending, undefined);
  assert.equal(badges.at(-1).text, "1");
});

test("existing credentials suppress reminders; locking, navigation and expiry discard pending credentials", async () => {
  duplicate = true;
  assert.deepEqual((await send(submitted, page)).data, { duplicate: true });
  duplicate = false;
  await send(submitted, page);
  operationFailure = "locked";
  assert.deepEqual((await send({ action: "login-pending" }, page)).data, {
    enabled: true,
    pending: false,
  });
  assert.equal((await send(submitted, page)).error, "locked");
  operationFailure = undefined;
  await send(submitted, page);
  tabURL = "https://elsewhere.test/";
  tabUpdated(7, { url: tabURL });
  tabURL = "https://example.com/login";
  assert.equal((await send({ action: "matches" })).data.pending, undefined);
  await send(submitted, page);
  const now = Date.now;
  Date.now = () => now() + 120001;
  try {
    assert.equal((await send({ action: "matches" })).data.pending, undefined);
  } finally {
    Date.now = now;
  }
  await send(submitted, page);
  await send({
    action: "configure-reminder",
    origin: "https://example.com",
    tabId: 7,
    enabled: false,
  });
  assert.equal((await send(submitted, page)).error, "forbidden");
  assert.equal(scripts.size, 0);
  assert.equal(fetches, 0);
});

test("turning off one site persists an exception without disabling other sites", async () => {
  assert.deepEqual((await send({ action: "login-pending" }, page)).data, {
    enabled: false,
    pending: false,
  });
  assert.ok(stored.reminderDisabledOrigins.includes("https://example.com"));
  tabURL = "https://new.example.test/login";
  const another = { ...page, url: tabURL, tab: { id: 7, url: tabURL } };
  assert.equal((await send(submitted, another)).data.pending, true);
  await send({ action: "login-dismiss" }, another);
  tabURL = "https://example.com/login";
  await send({
    action: "configure-reminder",
    origin: "https://example.com",
    tabId: 7,
    enabled: true,
  });
  assert.equal((await send(submitted, page)).data.pending, true);
  await send({ action: "login-dismiss" }, page);
});

test("icon badges count website accounts, show zero for empty password forms, and prioritize pending logins", async () => {
  accountCount = 0;
  await send({ action: "login-pending", hasPassword: false }, page);
  assert.equal(badges.at(-1).text, "");
  await send({ action: "login-pending", hasPassword: true }, page);
  assert.equal(badges.at(-1).text, "0");
  accountCount = 3;
  await send({ action: "login-pending", hasPassword: false }, page);
  assert.equal(badges.at(-1).text, "3");
  await send(submitted, page);
  assert.equal(badges.at(-1).text, "+");
  await send({ action: "login-open" }, page);
  assert.equal(
    createdTabs.at(-1).url,
    `chrome-extension://${extension}/popup.html?sourceTabId=7`,
  );
  assert.equal(createdTabs.at(-1).url.includes(submitted.password), false);
  await send({ action: "login-dismiss" }, page);
  assert.equal(badges.at(-1).text, "3");
  accountCount = 120;
  await send({ action: "matches" });
  assert.equal(badges.at(-1).text, "99+");
  operationFailure = "locked";
  await send({ action: "login-pending" }, page);
  assert.equal(badges.at(-1).text, "");
  operationFailure = undefined;
  accountCount = 1;
});

test("pending login survives same-origin redirects, dismissal stays dismissed, and changed-origin save is denied", async () => {
  await send(submitted, page);
  const before = (await send({ action: "matches", tabId: 7 })).data.pending;
  tabURL = "https://example.com/complete";
  tabUpdated(7, { url: tabURL });
  const landing = { ...page, url: tabURL, tab: { id: 7, url: tabURL } };
  assert.equal(
    (await send({ action: "login-pending" }, landing)).data.pending,
    true,
  );
  assert.equal(
    (await send({ action: "matches", tabId: 7 })).data.pending.id,
    before.id,
  );
  await send({ action: "login-dismiss" }, landing);
  assert.equal(
    (await send({ action: "login-pending" }, landing)).data.pending,
    false,
  );
  await send(submitted, landing);
  tabURL = "https://elsewhere.test/complete";
  tabUpdated(7, { url: tabURL });
  const savesBefore = nativeCalls.filter((c) => c.op === "save").length;
  assert.equal((await send({ action: "save-captured", ...before })).ok, false);
  assert.equal(nativeCalls.filter((c) => c.op === "save").length, savesBefore);
  tabURL = "https://example.com/login";
  assert.equal(
    (await send({ action: "login-pending" }, page)).data.pending,
    false,
  );
});

test("navigation completion re-announces only pending metadata, preserves expiry, and never reopens dismissed login", async () => {
  tabURL = "https://example.com/login";
  const result = await send(submitted, page);
  const notice = result.data.notice;
  const initial = pageCalls.at(-1)[1];
  assert.equal(initial.action, "reminder-pending");
  assert.deepEqual(initial.notice, notice);
  assert.equal(JSON.stringify(initial).includes(submitted.password), false);
  assert.equal(JSON.stringify(initial).includes(submitted.username), false);
  const before = pageCalls.length;
  tabUpdated(7, { status: "complete" }, { url: "https://example.com/done" });
  assert.equal(pageCalls.length, before + 1);
  assert.deepEqual(pageCalls.at(-1)[1].notice, notice);
  await send({ action: "login-dismiss" }, page);
  const afterDismiss = pageCalls.length;
  tabUpdated(7, { status: "complete" }, { url: "https://example.com/done" });
  assert.equal(pageCalls.length, afterDismiss);
  assert.equal(pageCalls.at(-1)[1].id, notice.id);
  assert.equal(idleInterval, 3600);
  await send(submitted, page);
  idleChanged("locked");
  assert.equal((await send({ action: "matches" })).data.pending, undefined);
});

test("inline offers expose metadata only and bind one-shot fills to document and exact URL", async () => {
  stored.mode = "native"; operationFailure = undefined; nativeFailure = undefined; accountCount = 2;
  tabURL = "https://example.com/login";
  const source = {...page, documentId: "synthetic-document"};
  assert.equal((await send({action:"inline-availability"}, {...source, frameId:-1})).error,"forbidden");
  assert.equal((await send({action:"inline-availability"}, page)).error,"forbidden");
  const available = await send({action:"inline-availability"}, source);
  assert.equal(available.data.count,2);
  const offer = (await send({action:"inline-accounts"}, source)).data;
  assert.equal(offer.accounts.length,2);
  assert.equal(JSON.stringify(offer).includes("synthetic-only"),false);
  assert.equal(offer.accounts[0].password,undefined);
  const fill = {action:"inline-fill", token:offer.token,id:"fixture-1",deliveryToken:"chosen-field"};
  assert.equal((await send(fill, source)).ok,true);
  assert.deepEqual(pageCalls.at(-1)[2],{documentId:"synthetic-document"});
  assert.equal(pageCalls.at(-1)[1].deliveryToken,"chosen-field");
  assert.equal((await send(fill, source)).error,"expired");
  const next = (await send({action:"inline-accounts"}, source)).data;
  assert.equal((await send({...fill,token:next.token}, {...source,documentId:"other-document"})).error,"expired");
  const moving = (await send({action:"inline-accounts"}, source)).data;
  tabURL = "https://example.com/next";
  assert.equal((await send({...fill,token:moving.token}, {...source,url:tabURL})).error,"expired");
  tabURL="https://example.com/login";
  const missing = (await send({action:"inline-accounts"}, source)).data;
  assert.equal((await send({...fill,token:missing.token,id:"not-offered"},source)).error,"expired");
  const locked = (await send({action:"inline-accounts"}, source)).data;
  operationFailure="locked";
  const before=pageCalls.filter(c=>c[1].action==="inline-deliver").length;
  assert.equal((await send({...fill,token:locked.token}, source)).ok,false);
  assert.equal(pageCalls.filter(c=>c[1].action==="inline-deliver").length,before);
  assert.equal((await send({action:"inline-availability"}, source)).data.count,0);
  operationFailure=undefined;
});

test("idle locking invalidates a fill already waiting after credential retrieval", async () => {
  stored.mode="native"; operationFailure=undefined; tabURL="https://example.com/login";
  const source={...page,documentId:"lock-race"};
  const offer=(await send({action:"inline-accounts"},source)).data;
  let release, entered;
  const paused=new Promise(resolve=>entered=resolve);
  const resume=new Promise(resolve=>release=resolve);
  let calls=0;
  getTabHook=async()=>{if(++calls===2){entered();await resume;}};
  const before=pageCalls.filter(c=>c[1].action==="inline-deliver").length;
  const pendingFill=send({action:"inline-fill",token:offer.token,id:"fixture",deliveryToken:"live-input"},source);
  await paused; idleChanged("locked"); release();
  assert.equal((await pendingFill).ok,false);
  assert.equal(pageCalls.filter(c=>c[1].action==="inline-deliver").length,before);
  assert.ok(pageCalls.some(c=>c[1].action==="inline-cancel"));
  getTabHook=undefined;
});


test("inline embedded login binds same-origin frame and top-page navigation independently", async () => {
  stored.mode="native"; operationFailure=undefined; accountCount=1; tabURL="https://example.com/app/home";
  const frame={...page,url:"https://example.com/user/login",frameId:3,documentId:"embedded-login"};
  assert.equal((await send({action:"inline-availability"},frame)).data.count,1);
  const offer=(await send({action:"inline-accounts"},frame)).data;
  const fill={action:"inline-fill",token:offer.token,id:"fixture",deliveryToken:"embedded-input"};
  assert.equal((await send(fill,frame)).ok,true);
  assert.deepEqual(pageCalls.at(-1)[2],{documentId:"embedded-login"});
  const other=(await send({action:"inline-accounts"},frame)).data;
  assert.equal((await send({...fill,token:other.token},{...frame,frameId:4})).ok,false);
  const navigating=(await send({action:"inline-accounts"},frame)).data;
  tabURL="https://example.com/app/next";
  assert.equal((await send({...fill,token:navigating.token},frame)).ok,false);
});

test("inline embedded login rejects cross-origin frames before accessing vault", async () => {
  stored.mode="native"; operationFailure=undefined; tabURL="https://example.com/app/home";
  const frame={...page,url:"https://other.example/login",frameId:3,documentId:"foreign-frame"};
  assert.equal((await send({action:"inline-availability"},frame)).error,"changed-origin");
  assert.equal((await send({action:"inline-accounts"},frame)).error,"changed-origin");
});


test("same-origin iframe captures show metadata-only notices in the main document", async () => {
  stored.mode="native"; operationFailure=undefined; duplicate=false; tabURL="https://example.com/app/home";
  await send({action:"configure-reminder",origin:"https://example.com",tabId:7,enabled:true});
  const embedded={...page,url:"https://example.com/user/login",frameId:3,documentId:"iframe-save"};
  const result=await send(submitted,embedded);
  assert.equal(result.data.pending,true);
  const notice=pageCalls.filter(c=>c[1].action==="reminder-pending").at(-1);
  assert.deepEqual(notice[2],{frameId:0});
  assert.equal(JSON.stringify(notice).includes(submitted.password),false);
  assert.equal((await send(submitted,embedded)).data.notice.id,result.data.notice.id);
  assert.equal((await send({action:"login-dismiss"},embedded)).error,"forbidden");
  assert.equal((await send(submitted,{...embedded,url:"https://foreign.test/login"})).ok,false);
  assert.equal((await send(submitted,{...embedded,origin:"null"})).ok,false);
  await send({action:"login-dismiss"},{...page,url:tabURL});
});

test("dismiss, disable, lock and cross-origin navigation cancel in-flight login capture", async () => {
  for(const action of ["dismiss","disable","idle","navigate","lock"]) {
    stored.mode="native";operationFailure=undefined;duplicate=false;tabURL="https://example.com/login";
    await send({action:"configure-reminder",origin:"https://example.com",tabId:7,enabled:true});
    await send({action:"login-dismiss"},page);
    let release, entered;
    const paused=new Promise(resolve=>entered=resolve), resume=new Promise(resolve=>release=resolve);
    let calls=0; getTabHook=async()=>{if(++calls===2){entered();await resume;}};
    const before=pageCalls.filter(c=>c[1].action==="reminder-pending").length;
    const capturing=send(submitted,page); await paused;
    let locking;
    if(action==="dismiss") await send({action:"login-dismiss"},page);
    if(action==="disable") await send({action:"configure-reminder",origin:"https://example.com",tabId:7,enabled:false});
    if(action==="idle") idleChanged("locked");
    if(action==="lock") locking=send({action:"lock"});
    if(action==="navigate") {tabURL="https://foreign.test/";tabUpdated(7,{url:tabURL});tabURL="https://example.com/login";tabUpdated(7,{url:tabURL});}
    release(); assert.equal((await capturing).ok,false,action);if(locking)await locking;
    getTabHook=undefined;
    assert.equal(pageCalls.filter(c=>c[1].action==="reminder-pending").length,before,action);
    assert.equal((await send({action:"matches"})).data.pending,undefined,action);
  }
});

test("embedded capture writes only after trusted popup confirmation and then clears the notice", async () => {
  stored.mode="native"; operationFailure=undefined; duplicate=false; tabURL="https://example.com/app/home";
  await send({action:"configure-reminder",origin:"https://example.com",tabId:7,enabled:true});
  const before=nativeCalls.filter(call=>call.op==="save").length;
  await send(submitted,{...page,url:"https://example.com/user/login",frameId:2,documentId:"confirm-iframe"});
  assert.equal(nativeCalls.filter(call=>call.op==="save").length,before);
  const pending=(await send({action:"matches"})).data.pending;
  assert.ok(pending);
  assert.equal((await send({action:"save-captured",...pending})).ok,true);
  assert.equal(nativeCalls.filter(call=>call.op==="save").length,before+1);
  const write=nativeCalls.filter(call=>call.op==="save").at(-1);
  assert.equal(write.origin,"https://example.com");
  assert.equal(write.username,submitted.username);
  assert.equal(write.password,submitted.password);
  assert.equal((await send({action:"matches"})).data.pending,undefined);
});

test("main-page status does not erase an embedded password-field badge", async () => {
  stored.mode="native";operationFailure=undefined;accountCount=0;tabURL="https://example.com/app/home";
  tabUpdated(7,{url:tabURL});
  await send({action:"login-pending",hasPassword:true},{...page,url:"https://example.com/user/login",frameId:2,documentId:"badge-iframe"});
  await send({action:"login-pending",hasPassword:false},{...page,url:tabURL});
  assert.equal(badges.at(-1).text,"0");
  accountCount=1;
});

test("cancellation before the first tab lookup and before queued capture prevents notices", {timeout: 10000}, async () => {
  for (const stage of ["lookup", "queue"]) {
    for(const cancellation of ["dismiss", "lock", "navigate"]) {
      stored.mode="native";operationFailure=undefined;duplicate=false;tabURL="https://example.com/login";
      tabUpdated(7,{url:tabURL});
      await send({action:"configure-reminder",origin:"https://example.com",tabId:7,enabled:true});
      await send({action:"login-dismiss"},page);
      let release,entered;const paused=new Promise(r=>entered=r),resume=new Promise(r=>release=r);let calls=0;
      getTabHook=async()=>{if(++calls===1){entered();await resume;}};
      const before=pageCalls.filter(c=>c[1].action==="reminder-pending").length;
      let front;
      if(stage==="queue"){front=send({action:"matches",tabId:7});await paused;}
      const capture=send(submitted,page);
      if(stage==="lookup")await paused;
      let lock;
      if(cancellation==="dismiss")await send({action:"login-dismiss"},page);
      if(cancellation==="lock")lock=send({action:"lock"});
      if(cancellation==="navigate"){tabURL="https://foreign.test/";tabUpdated(7,{url:tabURL});tabURL="https://example.com/login";tabUpdated(7,{url:tabURL});}
      release();if(front)await front;
      assert.equal((await capture).ok,false,stage+":"+cancellation);if(lock)await lock;
      getTabHook=undefined;
      assert.equal(pageCalls.filter(c=>c[1].action==="reminder-pending").length,before);
    }
  }
});

test("native edit routes metadata only and rejects stale or unscoped requests", async () => {
  stored.mode = "native"; accountCount = 1; tabURL = "https://example.com/login";
  const request = { action: "edit-native-entry", tabId: 7, origin: "https://example.com", id: "fixture" };
  const start = nativeCalls.length, pageStart = pageCalls.length;
  assert.equal((await send(request)).ok, true);
  const calls = nativeCalls.slice(start);
  assert.deepEqual(calls.map(value => value.op), ["matches", "open-entry"]);
  assert.equal(calls.at(-1).id, "fixture");
  assert.equal(calls.some(value => "password" in value || "username" in value), false);
  assert.equal(pageCalls.length, pageStart);
  assert.equal((await send({...request, id:"unrelated"})).error, "invalid-entry");
  assert.equal((await send({...request, accountId:"missing"})).error, "invalid-entry");
  assert.equal((await send({...request, origin:"https://other.test"})).error, "changed-origin");
  assert.equal((await send(request, {id:extension,url:tabURL,tab:{id:7,url:tabURL}})).error, "forbidden");
  let reads = 0;
  getTabHook = async () => { if (++reads === 2) tabURL="https://other.test/login"; };
  assert.equal((await send(request)).error, "changed-origin");
  getTabHook = undefined; tabURL="https://example.com/login";
  operationFailure = "locked";
  assert.equal((await send(request)).error, "locked");
  operationFailure = undefined;
  stored.mode = "independent";
  assert.equal((await send(request)).error, "native-app");
  stored.mode = "native";
});
