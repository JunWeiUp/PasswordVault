import {build} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
const result = await build({entryPoints:['editor.js'],bundle:true,format:'iife',target:'safari16',minify:true,write:false,metafile:true,legalComments:'none'});
const js = result.outputFiles[0].text.replaceAll('</script','<\\/script');
const css = await fs.readFile('style.css','utf8');
const hash = createHash('sha256').update(js).digest('base64');
const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'sha256-${hash}'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; media-src 'none'; font-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"><style>${css}</style></head><body><div id="editor"></div><script>${js}</script></body></html>`;
await fs.mkdir('../Resources',{recursive:true});
await fs.writeFile('../Resources/NoteEditor.html',html);
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs).filter(p=>p.includes('node_modules/'))) {
 let dir = path.dirname(path.resolve(input));
 while(dir !== path.dirname(dir)) {
  try {
   const pkg=JSON.parse(await fs.readFile(path.join(dir,'package.json'),'utf8'));
   if(pkg.name) {packages.set(dir,pkg);break;}
  } catch {}
  dir=path.dirname(dir);
 }
}
let notices='PasswordVault bundled note editor — third-party notices\n\n';
for (const [dir,pkg] of [...packages].sort((a,b)=>a[1].name.localeCompare(b[1].name))) {
 const files=await fs.readdir(dir);
 const licenses=files.filter(name=>/^(license|licence|copying)(\.|$)/i.test(name));
 if(!licenses.length) throw new Error(`Missing license for ${pkg.name}`);
 notices+=`${pkg.name} ${pkg.version} (${pkg.license})\n${'='.repeat(60)}\n`;
 for(const file of licenses) notices+=await fs.readFile(path.join(dir,file),'utf8')+'\n';
 notices+='\n';
}
await fs.writeFile('../Resources/NoteEditor-LICENSES.txt',notices);
console.log(`Bundled local note editor: ${Buffer.byteLength(html)} bytes; ${packages.size} dependency notices.`);
