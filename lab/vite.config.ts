import preact from "@preact/preset-vite";
import { defineConfig } from "vitest/config";

export default defineConfig({
  root: ".",
  publicDir: false,
  plugins: [preact()],
  test: {
    environment: "node",
  },
});
