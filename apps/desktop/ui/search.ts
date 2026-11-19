// Shared local search for the list and Quick Access. Only explicitly selected
// display fields are indexed; secrets and internal IDs must not affect results.
export type SearchItem = { type: string; title?: string; [key: string]: any };
type SearchEntry = { title: string; fields: string[]; compact: string[] };
let index = new WeakMap<SearchItem, SearchEntry>();

export function clearSearchIndex() {
  index = new WeakMap();
}

function normalize(value: string): string {
  return value.normalize("NFKD").toLowerCase().replace(/\p{M}/gu, "").replace(/\s+/g, " ").trim();
}
const compact = (value: string) => value.replace(/[\s\-‐‑–—().+]/g, "");

// Field extraction stays allowlisted: recursively serializing an entry would
// accidentally include passwords, TOTP seeds, private keys and history.
function displayFields(item: SearchItem): string[] {
  const values: string[] = [];
  const add = (...fields: unknown[]) => {
    for (const field of fields) {
      if (typeof field === "string" || typeof field === "number") values.push(String(field));
      else if (Array.isArray(field)) add(...field);
    }
  };
  add(item.title, item.username, item.email, item.url, item.issuer, item.note,
    item.category, item.slug, item.tags, item.colorLabel, item.network, item.address, item.__noteSearchText);
  const each = (value: unknown, visit: (field: any) => void) => {
    if (Array.isArray(value)) for (const field of value) if (field && typeof field === "object") visit(field);
  };
  each(item.noteProperties, (prop) => add(prop.key, prop.value));
  each(item.accounts, (account) => add(account.label, account.username, account.email, account.url));
  each(item.customFields, (field) => {
    add(field.label, field.group);
    if (["text", "url", "email", "date"].includes(field.kind)) add(field.value);
  });
  each(item.passkeys, (key) => add(key.rpId, key.userName));
  if (item.card) add(item.card.cardholder, item.card.brand, item.card.number,
    item.card.expiryMonth, item.card.expiryYear);
  if (item.identity) {
    const person = item.identity;
    add(person.firstName, person.lastName, `${person.lastName ?? ""}${person.firstName ?? ""}`,
      person.email, person.phone, person.address1, person.address2, person.city,
      person.region, person.postalCode, person.country, person.company);
  }
  if (item.device) {
    const device = item.device;
    add(device.host, device.port, device.username, device.authMethod, device.aliases, device.notes);
    each(device.services, (service) => add(service.name, service.kind, service.remotePort, service.localPort, service.path));
    each(device.commands, (command) => {
      add(command.label, command.title);
      if (!command.secret) add(command.text);
    });
    each(device.files, (file) => add(file.name, file.mime));
  }
  // In summaries the core supplies just these attributes, without transferring
  // rich editor structures. Once opened, the full note replaces its summary.
  const rich = (node: any, depth = 0) => {
    if (!node || typeof node !== "object" || depth > 64) return;
    add(node.text);
    if (node.type === "vaultImage" || node.type === "vaultAttachment") add(node.attrs?.name, node.attrs?.caption);
    each(node.marks, (mark) => { if (mark.type === "link") add(mark.attrs?.href); });
    each(node.content, (child) => rich(child, depth + 1));
  };
  rich(item.noteDocument);
  return values;
}

function entry(item: SearchItem): SearchEntry {
  let cached = index.get(item);
  if (!cached) {
    const fields = displayFields(item).map(normalize).filter(Boolean);
    const displayTitle = item.type === "device" ? (item.title?.trim() || item.device?.host?.trim() || "") : (item.title ?? "");
    cached = { title: normalize(displayTitle), fields, compact: fields.map(compact) };
    index.set(item, cached);
  }
  return cached;
}

/** Every whitespace-separated keyword must match somewhere in the same item.
 *  Preserve the caller's order for equally relevant results (pins/date, etc.). */
export function searchItems<T extends SearchItem>(items: readonly T[], query: string): T[] {
  const text = normalize(query);
  if (!text) return [...items];
  const terms = [...new Set(text.split(" "))];
  return items.flatMap((item) => {
    const data = entry(item);
    const matches = terms.every((term) => {
      if (data.fields.some((field) => field.includes(term))) return true;
      // Phone/card formatting may differ between the stored value and input.
      // Require several digits so punctuation-only queries never match all rows.
      const digits = compact(term);
      return /^\d{3,}$/.test(digits) && data.compact.some((field) => field.includes(digits));
    });
    if (!matches) return [];
    const rank = data.title === text ? 0 : data.title.startsWith(text) ? 1
      : terms.every((term) => data.title.includes(term)) ? 2 : 3;
    return [{ item, rank }];
  }).sort((a, b) => a.rank - b.rank).map(({ item }) => item);
}
