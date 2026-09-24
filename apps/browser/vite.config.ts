import { defineConfig } from "vite";
export default defineConfig({
  base: "./",
  build: {
    modulePreload: false,
    target: "es2022",
    assetsInlineLimit: 0,
    rollupOptions: {
      input: {
        app: "index.html",
        popup: "popup.html",
        background: "src/background.ts",
        content: "src/content.ts",
        "login-observer": "src/login-observer.ts",
        "inline-fields": "src/inline-fields.ts",
      },
      output: {
        entryFileNames: "[name].js",
        chunkFileNames: "assets/[name]-[hash].js",
      },
    },
  },
  worker: { format: "es" },
  server: { host: "127.0.0.1", strictPort: true },
});
