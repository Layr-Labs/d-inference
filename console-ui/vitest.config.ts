import { defineConfig, configDefaults } from "vitest/config";
import path from "path";

export default defineConfig({
  oxc: {
    jsx: "automatic",
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./__tests__/setup.ts"],
    // Playwright specs live in e2e/ and use @playwright/test (not Vitest).
    // Vitest's default include would otherwise pick up their *.spec.ts files.
    exclude: [...configDefaults.exclude, "e2e/**"],
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
});
