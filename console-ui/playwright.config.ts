import { defineConfig, devices } from "@playwright/test";

// Browser-level E2E for the console UI. Unlike the jsdom Vitest unit tests,
// these drive a REAL browser against a running app, so they catch SSR hydration
// and client-navigation regressions that jsdom cannot — e.g. the hydration
// mismatch that silently broke next/link navigation app-wide (#457/#463).
//
// Hermetic by default: the app boots with Privy UNCONFIGURED (mock-auth mode),
// so no real Privy tenant, coordinator, or secrets are needed. The suite asserts
// shell behaviour (routing + no hydration errors), not authenticated data flows.

const PORT = Number(process.env.PLAYWRIGHT_PORT ?? 3100);
const BASE_URL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI ? [["github"], ["list"]] : "list",
  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    // The dev server is sufficient for routing/hydration coverage and avoids a
    // slow production build in CI. Privy unset => mock-auth, so the shell renders
    // without any backend. PORT is read by `next dev`.
    command: "npm run dev",
    url: BASE_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    env: {
      PORT: String(PORT),
      NEXT_PUBLIC_PRIVY_APP_ID: "",
    },
  },
});
