import { defineConfig, devices } from "@playwright/test";

// Browser-level E2E for the console UI. Unlike the jsdom Vitest unit tests,
// these drive a REAL browser against a running app, so they catch SSR hydration
// and client-navigation regressions that jsdom cannot — e.g. the hydration
// mismatch that silently broke next/link navigation app-wide (#457/#463).
//
// Hermetic: the app boots with Privy UNCONFIGURED + NEXT_PUBLIC_E2E_AUTH=1, so
// mock-auth returns a usable token+user (no real Privy tenant or secrets), and
// every coordinator call (/api/*) is route-mocked in e2e/fixtures.ts. That lets
// the suite drive real authenticated flows (provider onboarding, API-key create,
// chat send) in addition to shell routing + hydration checks — all with no
// backend.

const PORT = Number(process.env.PLAYWRIGHT_PORT ?? 3100);
const BASE_URL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI ? [["github"], ["list"]] : "list",
  // The dev server compiles routes on-demand; under parallel workers a route's
  // first hit can take several seconds. A generous assertion timeout absorbs
  // cold compiles without masking real hangs (a hydration break still fails).
  expect: { timeout: 15_000 },
  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
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
      // Privy unset => mock-auth; E2E flag makes mock-auth return a usable
      // token + user so authenticated flows can run against route-mocked APIs.
      NEXT_PUBLIC_PRIVY_APP_ID: "",
      NEXT_PUBLIC_E2E_AUTH: "1",
    },
  },
});
