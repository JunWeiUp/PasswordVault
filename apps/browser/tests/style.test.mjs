import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
const css=await readFile(new URL("../src/style.css",import.meta.url),"utf8");
function block(selector){const start=css.indexOf(`${selector} {`);assert.ok(start>=0,selector);return css.slice(start,css.indexOf("}",start));}
function tokens(text){return Object.fromEntries([...text.matchAll(/--([\w-]+):\s*([^;]+);/g)].map(m=>[m[1],m[2].trim()]));}
test("style colors come only from the light and dark design tokens",()=>{
 const light=tokens(block(":root")),dark=tokens(block(':root[data-theme="dark"]'));
 assert.equal(light.blue,"#3265db");assert.equal(dark.blue,"#5b8cff");
 assert.equal(light.bg,"#e9ecf1");assert.equal(dark.bg,"#0e1116");
 for(const name of ["green","green-soft","orange","orange-soft","red","red-soft"]){assert.ok(light[name],name);assert.ok(dark[name],`dark ${name}`);}
 const outside=css.split("\n").filter(line=>!/^\s*--[\w-]+:/.test(line)).filter(line=>/#[0-9a-fA-F]{3,8}\b|rgba?\(|\bwhite\b(?!-)/.test(line.replace(/white-space/g,"")));
 assert.deepEqual(outside,[]);
});
