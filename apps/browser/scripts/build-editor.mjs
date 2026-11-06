import { build } from "../../shared/note-editor/node_modules/esbuild/lib/main.js";
import { readFile, writeFile, copyFile } from "node:fs/promises";
const version = encodeURIComponent(JSON.parse(await readFile("package.json", "utf8")).version);
await build({
  entryPoints: ["../shared/note-editor/editor.js"],
  bundle: true,
  format: "iife",
  target: "es2022",
  minify: true,
  outfile: "dist/note-editor.js",
});
await copyFile("../shared/note-editor/style.css", "dist/note-editor.css");
await copyFile("editor/bridge.js", "dist/note-editor-bridge.js");
await writeFile(
  "dist/note-editor.html",
  `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src blob:; connect-src 'none'; base-uri 'none'; form-action 'none'"><link rel="stylesheet" href="note-editor.css?v=${version}"></head><body><div id="editor"></div><script src="note-editor-bridge.js?v=${version}"></script><script src="note-editor.js?v=${version}"></script></body></html>`,
);
await copyFile(
  "../shared/note-editor/dist/NoteEditor-LICENSES.txt",
  "dist/NoteEditor-LICENSES.txt",
);
