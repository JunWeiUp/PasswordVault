// Identity document data. Released cores whitelist identity keys, so documents
// live in `customFields` under fixed ids shared with the iOS/Android clients.
export type DocumentKind = "text" | "concealed" | "date";
export const DOCUMENT_GROUP = "document";
export const DOCUMENT_FIELDS: readonly { id: string; label: string; kind: DocumentKind }[] = [
  { id: "document.type", label: "证件类型", kind: "text" },
  { id: "document.number", label: "证件号码", kind: "concealed" },
  { id: "document.issuer", label: "签发机关", kind: "text" },
  { id: "document.issueDate", label: "签发日期", kind: "date" },
  { id: "document.expiryDate", label: "有效期至", kind: "date" },
];
const known = new Set(DOCUMENT_FIELDS.map((f) => f.id));
export const isDocumentField = (field: any) => known.has(field?.id);
export const documentValue = (fields: any[] | undefined, id: string): string =>
  String((fields ?? []).find((f) => f?.id === id)?.value ?? "");
/** Dates are stored as `YYYY-MM-DD`; an empty value is allowed. */
export const validDocumentDate = (value: string) => {
  if (!value) return true;
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3];
};
/**
 * Returns a new custom field list with one document value set. Existing fields
 * keep their order, label and any unknown keys; a missing field is appended
 * only when it receives a value.
 */
export function setDocumentValue(fields: any[] | undefined, id: string, value: string): any[] {
  const spec = DOCUMENT_FIELDS.find((f) => f.id === id);
  if (!spec) throw new Error(`unknown document field ${id}`);
  const list = [...(fields ?? [])];
  const index = list.findIndex((f) => f?.id === id);
  if (index >= 0) list[index] = { ...list[index], value };
  else if (value) list.push({ id, group: DOCUMENT_GROUP, label: spec.label, kind: spec.kind, value });
  return list;
}
