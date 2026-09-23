import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import wasm from "vite-plugin-wasm";
import { fileURLToPath, URL } from "node:url";

// COOP/COEP headers let workers share memory (SharedArrayBuffer) for WASM threads
// and keep WebCodecs/OPFS usable in a cross-origin-isolated context.
const isolationHeaders = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
};

export default defineConfig({
  plugins: [react(), wasm()],
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  worker: { format: "es", plugins: () => [wasm()] },
  server: {
    port: 5173,
    headers: isolationHeaders,
    // Same-origin API in development so Better Auth cookies work without CORS changes.
    proxy: { "/api": { target: "http://localhost:3000", changeOrigin: true } },
  },
  preview: { headers: isolationHeaders },
  build: { target: "es2023", sourcemap: true },
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
    setupFiles: ["src/test-setup.ts"],
  },
});
