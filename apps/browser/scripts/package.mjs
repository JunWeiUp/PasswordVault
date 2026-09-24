import {
  readFile,
  writeFile,
  cp,
  mkdir,
  stat,
  readdir,
} from "node:fs/promises";
const identity = JSON.parse(
  await readFile(new URL("../identity.json", import.meta.url)),
);
const metadata = JSON.parse(
  await readFile(new URL("../package.json", import.meta.url)),
);
await mkdir("dist/icons", { recursive: true });
await cp("../../assets/icon/icon.png", "dist/icons/brand.png").catch(
  async () => {
    await cp(
      "../macos/Resources/Assets.xcassets/BrandMark.imageset/brand.png",
      "dist/icons/brand.png",
    );
  },
);
const manifest = {
  manifest_version: 3,
  name: "PasswordVault",
  version: metadata.version,
  description:
    "Private notes and credentials. Connect to Mac or use an independent encrypted vault.",
  minimum_chrome_version: "120",
  key: identity.publicKey,
  permissions: ["storage", "activeTab", "scripting", "nativeMessaging", "idle"],
  host_permissions: ["https://*/*", "http://*/*"],
  content_scripts: [
    {
      matches: ["https://*/*", "http://*/*"],
      js: ["login-observer.js"],
      all_frames: true,
      run_at: "document_idle",
    },
    {
      matches: ["https://*/*", "http://*/*"],
      js: ["inline-fields.js"],
      all_frames: true,
      run_at: "document_idle",
    },
  ],
  action: { default_popup: "popup.html", default_title: "PasswordVault" },
  background: { service_worker: "background.js", type: "module" },
  options_page: "index.html",
  icons: { 128: "icons/brand.png" },
  content_security_policy: {
    extension_pages:
      "script-src 'self' 'wasm-unsafe-eval'; object-src 'none'; base-uri 'none'",
  },
};
await writeFile("dist/manifest.json", JSON.stringify(manifest, null, 2) + "\n");
async function size(dir) {
  let result = 0;
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = dir + "/" + entry.name;
    result += entry.isDirectory() ? await size(path) : (await stat(path)).size;
  }
  return result;
}
const bytes = await size("dist");
if (bytes > 8 * 1024 * 1024)
  throw new Error("Extension exceeds the 8 MiB build budget");
console.log(`Extension package: ${(bytes / 1048576).toFixed(2)} MiB`);
