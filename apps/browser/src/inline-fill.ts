import { webOrigin } from "./security";
import type { Request } from "./core";

type Offer = {
  tabId: number;
  origin: string;
  documentId: string;
  url: string;
  topUrl: string;
  frameId: number;
  expires: number;
  accounts: {
    id: string;
    accountId?: string;
    title: string;
    username: string;
  }[];
};
const offers = new Map<string, Offer>();
const filling = new Set<Offer>();
let generation = 0;
export function clearInlineOffers() {
  generation++;
  const current = new Set([...offers.values(), ...filling]);
  offers.clear();
  for (const offer of current)
    void chrome.tabs
      .sendMessage(
        offer.tabId,
        { action: "inline-cancel" },
        { documentId: offer.documentId },
      )
      .catch(() => {});
}
export async function handleInline(
  request: Record<string, any>,
  sender: chrome.runtime.MessageSender,
  core: (request: Request) => Promise<any>,
) {
  if (
    sender.id !== chrome.runtime.id ||
    typeof sender.frameId !== "number" ||
    sender.frameId < 0 ||
    !sender.tab?.id ||
    !sender.url ||
    !sender.documentId
  )
    throw new Error("forbidden");
  const epoch = generation;
  const ensureCurrent = () => {
    if (epoch !== generation) throw new Error("locked");
  };
  const tabId = sender.tab.id,
    origin = webOrigin(sender.url),
    documentId = sender.documentId;
  const tab = await chrome.tabs.get(tabId);
  if (!tab.url || webOrigin(tab.url) !== origin)
    throw new Error("changed-origin");
  for (const [key, offer] of offers)
    if (offer.expires <= Date.now()) offers.delete(key);
  if (request.action === "inline-availability") {
    try {
      const accounts = await core({ op: "matches", origin });
      ensureCurrent();
      return { count: accounts.length };
    } catch {
      return { count: 0 };
    }
  }
  if (request.action === "inline-accounts") {
    const matches = await core({ op: "matches", origin });
    ensureCurrent();
    const accounts = matches.slice(0, 100).map((a: any) => ({
      id: String(a.id),
      accountId: typeof a.accountId === "string" ? a.accountId : undefined,
      title: String(a.title ?? ""),
      username: String(a.username ?? ""),
    }));
    // One short-lived offer per document. Never put credentials in DOM or storage.
    for (const [key, offer] of offers)
      if (offer.tabId === tabId) offers.delete(key);
    const token = crypto.randomUUID();
    if (offers.size >= 128) offers.delete(offers.keys().next().value!);
    offers.set(token, {
      tabId,
      origin,
      documentId,
      url: sender.url,
      topUrl: tab.url!,
      frameId: sender.frameId,
      accounts,
      expires: Date.now() + 30_000,
    });
    return { token, accounts };
  }
  if (request.action !== "inline-fill") throw new Error("unsupported");
  const offer = offers.get(request.token);
  offers.delete(request.token);
  if (
    !offer ||
    offer.tabId !== tabId ||
    offer.origin !== origin ||
    offer.documentId !== documentId ||
    offer.topUrl !== tab.url ||
    offer.url !== sender.url ||
    offer.frameId !== sender.frameId ||
    !offer.accounts.some(
      (a) => a.id === request.id && a.accountId === request.accountId,
    ) ||
    typeof request.deliveryToken !== "string" ||
    request.deliveryToken.length > 128
  )
    throw new Error("expired");
  filling.add(offer);
  let credential: any;
  try {
    credential = await core({
      op: "fill",
      origin,
      id: request.id,
      accountId: request.accountId,
    });
    ensureCurrent();
    const current = await chrome.tabs.get(tabId);
    ensureCurrent();
    if (
      !current.url ||
      current.url !== offer.topUrl ||
      webOrigin(current.url) !== origin
    )
      throw new Error("changed-origin");
    const result = await chrome.tabs.sendMessage(
      tabId,
      {
        action: "inline-deliver",
        origin,
        deliveryToken: request.deliveryToken,
        username: credential.username,
        password: credential.password,
      },
      { documentId },
    );
    if (!result?.ok) throw new Error("field-changed");
    return {};
  } finally {
    filling.delete(offer);
    if (credential) {
      credential.password = "";
      credential.username = "";
    }
  }
}
