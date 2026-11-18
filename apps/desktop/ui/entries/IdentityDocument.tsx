// Identity document section: fixed-id custom fields shown with local labels.
import { Field, Group, SectionHead, T } from "../kit";
import { edit, type Item } from "../store";
import { c } from "../theme";
import { DOCUMENT_FIELDS, documentValue, setDocumentValue, validDocumentDate } from "./documents";

export function IdentityDocument(p: { item: Item; editing: boolean }) {
  const value = (id: string) => documentValue(p.item.customFields, id);
  const present = () => DOCUMENT_FIELDS.some((f) => value(f.id));
  const badDate = () => DOCUMENT_FIELDS.some((f) => f.kind === "date" && !validDocumentDate(value(f.id)));
  return (
    <If when={p.editing || present()}><>
      <SectionHead title="证件" />
      <Group>
        {DOCUMENT_FIELDS.map((f) => (
          <Field label={f.label} value={value(f.id)} secret={f.kind === "concealed"} editing={p.editing}
            placeholder={f.kind === "date" ? "YYYY-MM-DD" : undefined}
            onChange={(v) => edit(p.item.id, (d) => { d.customFields = setDocumentValue(d.customFields, f.id, v); })} />
        ))}
      </Group>
      <If when={badDate()}><T size={11.5} color={c().red}>日期请按 YYYY-MM-DD 填写。</T></If>
    </></If>
  );
}
