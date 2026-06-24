import type { Page, ConsoleMessage } from "@playwright/test";
import { test, expect } from "./fixtures";

// Patterns that indicate a React hydration mismatch — the failure class behind
// the broken-navigation regression (#457/#463): a divergent first client render
// makes React discard the server DOM, which breaks App Router client navigation
// app-wide. We assert these never appear. Covers both the verbose dev messages
// and the minified production error codes.
const HYDRATION_ERROR =
  /hydrat|did not match|text content does not match|server[- ]rendered HTML|Minified React error #(418|419|421|422|423|425)/i;

// Attach console/pageerror listeners and return a live array of hydration-error
// strings seen so far. Attach BEFORE navigating so nothing is missed.
function watchHydrationErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on("console", (msg: ConsoleMessage) => {
    if (msg.type() === "error" && HYDRATION_ERROR.test(msg.text())) errors.push(msg.text());
  });
  page.on("pageerror", (err: Error) => {
    if (HYDRATION_ERROR.test(err.message)) errors.push(err.message);
  });
  return errors;
}

// Wait until the client shell has actually rendered (a hydration-dependent
// element), so any hydration error has had a chance to surface.
async function waitForShell(page: Page) {
  await expect(page.getByRole("link", { name: "Chat" }).first()).toBeVisible();
}

const SHELL_ROUTES = [
  "/",
  "/stats",
  "/providers",
  "/providers/setup",
  "/providers/earnings",
  "/earn",
  "/api-console",
  "/models",
  "/billing",
  "/settings",
];

test.describe("console shell — hydration", () => {
  for (const route of SHELL_ROUTES) {
    test(`loads ${route} with no hydration error`, async ({ page }) => {
      const errors = watchHydrationErrors(page);
      await page.goto(route);
      await waitForShell(page);
      expect(errors, `hydration errors on ${route}`).toEqual([]);
    });
  }

  // A persisted verification-mode preference must not break hydration (the
  // class of bug behind #463, where reading localStorage during render diverged
  // the first client render from the server HTML). NOTE: this hermetic
  // mock-auth harness does NOT fully reproduce the production #463 break — the
  // verification-mode consumers (TrustBadge/E2ELockIndicator) only render
  // divergent DOM with real authenticated trust data — so treat this as a
  // general invariant guardrail, not a proof of that specific fix.
  test("hydrates cleanly with a persisted verification-mode preference", async ({ page }) => {
    await page.addInitScript(() => {
      window.localStorage.setItem("darkbloom-verification-mode", "technical");
    });
    const errors = watchHydrationErrors(page);
    await page.goto("/");
    await waitForShell(page);
    expect(errors, "hydration errors with a persisted verification mode").toEqual([]);
  });
});

test.describe("console shell — navigation", () => {
  test("sidebar links switch routes", async ({ page }) => {
    await page.goto("/");
    await waitForShell(page);

    await page.getByRole("link", { name: "Stats" }).first().click();
    await expect(page).toHaveURL(/\/stats$/);

    await page.getByRole("link", { name: "Provider Dashboard" }).first().click();
    await expect(page).toHaveURL(/\/providers$/);
  });

  // Pre-install (no linked machines), only the Dashboard tab is shown; Setup and
  // Earnings are gated behind having a provider linked (#462). Mock-auth has no
  // linked machines, so this is the pre-install state.
  test("provider dashboard hides Setup/Earnings tabs until a machine is linked (#462)", async ({ page }) => {
    await page.goto("/providers");
    await waitForShell(page);

    await expect(page.getByRole("link", { name: "Dashboard", exact: true })).toBeVisible();
    await expect(page.getByRole("link", { name: "Setup", exact: true })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Earnings", exact: true })).toHaveCount(0);
  });
});
