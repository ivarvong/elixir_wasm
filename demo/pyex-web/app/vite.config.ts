import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { resolve } from "node:path";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    target: "es2022",
    outDir: "dist",
    rollupOptions: {
      // MPA: / is the static landing page (runs Python via /api/run — no wasm
      // download), /play/ is the full in-browser playground.
      input: {
        landing: resolve(__dirname, "index.html"),
        play: resolve(__dirname, "play/index.html"),
      },
    },
  },
  worker: { format: "es" },
});
