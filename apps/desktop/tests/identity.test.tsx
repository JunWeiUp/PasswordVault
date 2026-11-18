import { expect, open, test } from "nsh/test";
import { searchItems } from "../ui/search";
import { DOCUMENT_FIELDS, documentValue, isDocumentField, setDocumentValue, validDocumentDate } from "../ui/entries/documents";
test("document fields use the shared custom-field schema and preserve other fields", () => {
  expect(DOCUMENT_FIELDS.map((f) => `${f.id}:${f.kind}`)).toEqual([
    "document.type:text", "document.number:concealed", "document.issuer:text", "document.issueDate:date", "document.expiryDate:date",
  ]);
  const legacy = { id: "legacy", label: "旧", kind: "text", value: "x", extra: 1 };
  const added = setDocumentValue([legacy], "document.number", "E1");
  expect(added[0]).toEqual(legacy);
  expect(added[1]).toEqual({ id: "document.number", group: "document", label: "证件号码", kind: "concealed", value: "E1" });
  const relabeled = [{ id: "document.type", group: "document", label: "Document type", kind: "text", value: "Passport", future: true }];
  const updated = setDocumentValue(relabeled, "document.type", "护照");
  expect(updated[0]).toEqual({ ...relabeled[0], value: "护照" });
  expect(relabeled[0].value).toBe("Passport");
  expect(setDocumentValue(undefined, "document.issuer", "")).toEqual([]);
  expect(documentValue(updated, "document.type")).toBe("护照");
  expect(isDocumentField(legacy)).toBe(false);
  expect(isDocumentField(updated[0])).toBe(true);
  expect(validDocumentDate("2031-02-28")).toBe(true);
  expect(validDocumentDate("2031-02-30")).toBe(false);
  expect(validDocumentDate("2031/02/01")).toBe(false);
  expect(validDocumentDate("")).toBe(true);
  expect(() => setDocumentValue([], "document.photo", "x")).toThrow();
  const person: any = { id: "p", type: "identity", title: "QA", identity: {}, customFields: setDocumentValue(setDocumentValue([], "document.type", "护照"), "document.number", "E7654321") };
  expect(searchItems([person], "护照").length).toBe(1);
  expect(searchItems([person], "E7654321").length).toBe(0);
});
test("identity documents are created, saved concealed and keep foreign fields", async () => {
  const app = await open("../ui/entries/IdentityHarness.tsx", { width: 1200, height: 1800, platform: "macos" });
  await app.press("text:准备测试库");
  await app.waitFor("text:证件");
  await app.type("label:证件类型", "护照");
  await app.type("label:证件号码", "E1234567");
  await app.type("label:有效期至", "2031-05-06");
  await app.press("text:保存并重读");
  await app.wait(500);
  await app.waitFor("text:号码已加密保存");
  expect(app.texts()).toContain("日期已保存");
  expect(app.texts()).toContain("旧字段保留");
  expect(app.texts()).toContain("未知字段保留");
  expect(app.texts()).toContain("字段数量 4");
  await app.press("text:切换编辑");
  await app.waitFor("text:护照");
  expect(app.texts()).not.toContain("E1234567");
  expect(app.texts()).toContain("••••••••••••");
  expect(app.texts()).toContain("2031-05-06");
  expect(app.texts()).toContain("会员号");
});
