import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import ts from "typescript";
const translations=JSON.parse(await readFile(new URL("../src/translations.en.json",import.meta.url),"utf8"));
const POPUP=["popup","NativeConnectionPanel","BackgroundSyncPanel","StructuredFill","AccountSecret","PasskeyApproval"];
test("explicit UI translations cover all literal calls and preserve placeholders",async()=>{
 for(const name of ["app","Capabilities","RecoveryPanel","HistoryDialog","WebDAVPanel","RichNoteEditor","PasskeyDetails","popup","NativeConnectionPanel","BackgroundSyncPanel","StructuredFill","AccountSecret","PasskeyApproval"]){
  const source=await readFile(new URL(`../src/${name}.tsx`,import.meta.url),"utf8");
  const file=ts.createSourceFile(name,source,99,true,4);
  function visit(node){
   if(ts.isCallExpression(node)&&node.expression.getText(file)==="t"&&ts.isStringLiteral(node.arguments[0]))assert.ok(translations[node.arguments[0].text],`${name}: ${node.arguments[0].text}`);
   if(ts.isJsxText(node)&&node.text.trim()!=="中文")assert.equal(/[\u3400-\u9fff]/.test(node.text),false,`${name}: unlocalized UI text`);
   if(POPUP.includes(name)&&(ts.isStringLiteral(node)||ts.isNoSubstitutionTemplateLiteral(node)||ts.isTemplateHead(node))&&/[\u3400-\u9fff]/.test(node.text)){const call=node.parent;assert.ok(ts.isCallExpression(call)&&call.expression.getText(file)==="t",`${name}: untranslated literal ${node.text}`);}
   ts.forEachChild(node,visit);
  }visit(file);
 }
 for(const [key,value]of Object.entries(translations))assert.deepEqual([...key.matchAll(/\{\w+\}/g)].map(m=>m[0]).sort(),[...value.matchAll(/\{\w+\}/g)].map(m=>m[0]).sort(),key);
});
test("popup status and error messages from shared modules have English translations",async()=>{
 for(const name of ["client","native-connection"]){
  const source=await readFile(new URL(`../src/${name}.ts`,import.meta.url),"utf8");
  for(const match of source.matchAll(/"([^"\n]*[\u3400-\u9fff][^"\n]*)"/g))assert.ok(translations[match[1]],`${name}: ${match[1]}`);
 }
});
