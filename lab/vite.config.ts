import { defineConfig } from "vitest/config";

export default defineConfig({
  root: ".",
  publicDir: false,
  test: {
    environment: "node",
  },
});
