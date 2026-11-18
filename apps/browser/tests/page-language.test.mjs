import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import ts from "typescript";
// In-page UI (content scripts) translates every visible string and reads the language from chrome.storage.
for(const [name,fn,table] of [["inline-fields","inlineText","INLINE_EN"],["login-observer","observerText","OBSERVER_EN"]]){
 test(`${name} shows English when the UI language is English`,async()=>{
  const source=await readFile(new URL(`../src/${name}.ts`,import.meta.url),"utf8");
  const file=ts.createSourceFile(name,source,99,true,3);
  let dictionary;const used=[];
  (function visit(node){
   if(ts.isVariableDeclaration(node)&&node.name.getText(file)===table)dictionary=Object.fromEntries(node.initializer.properties.map(p=>[p.name.text,p.initializer.text]));
   if(ts.isCallExpression(node)&&node.expression.getText(file)===fn&&ts.isStringLiteral(node.arguments[0]))used.push(node.arguments[0].text);
   if(ts.isStringLiteral(node)&&/[㐀-鿿]/.test(node.text)&&!(ts.isCallExpression(node.parent)&&node.parent.expression.getText(file)===fn)&&!(ts.isPropertyAssignment(node.parent)))assert.fail(`${name}: untranslated literal ${node.text}`);
   ts.forEachChild(node,visit);
  })(file);
  assert.ok(used.length>5);
  // Content scripts share one isolated world: keep every declaration inside the IIFE.
  assert.equal(source.replace(/^(\/\/.*\n)+/,"").startsWith("(() => {"),true);
  for(const key of used)assert.ok(dictionary[key]&&!/[㐀-鿿]/.test(dictionary[key]),key);
  assert.match(source,/chrome\.storage\.local\.get\("uiLanguage"\)/);
  assert.match(source,/chrome\.storage\.onChanged/);
  assert.equal(/prefers-color-scheme/.test(source),false);
 });
}
test("extension pages mirror the UI language for content scripts",async()=>{
 const source=await readFile(new URL("../src/i18n.ts",import.meta.url),"utf8");
 assert.match(source,/storage\?\.local\?\.set\(\{uiLanguage:language\}\)/);
});
