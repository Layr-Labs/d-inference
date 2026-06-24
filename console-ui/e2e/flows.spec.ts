import { test, expect, makeProvider, seedProviders } from "./fixtures";

// Authenticated user flows, driven in a real browser against route-mocked
// coordinator APIs (see fixtures.ts). These exercise actual product behaviour —
// provider onboarding, API-key creation, and chat — not just the shell.

test.describe("provider onboarding", () => {
  test("empty fleet shows the onboarding state and 'Set up a provider' navigates", async ({ page }) => {
    await page.goto("/providers");

    await expect(
      page.getByRole("heading", { name: /No provider machines linked yet/i }),
    ).toBeVisible();
    // Pre-install: Setup/Earnings tabs are gated off.
    await expect(page.getByRole("link", { name: "Setup", exact: true })).toHaveCount(0);

    await page.getByRole("link", { name: /Set up a provider/i }).click();
    await expect(page).toHaveURL(/\/providers\/setup$/);
  });

  test("a linked machine renders on the dashboard and unlocks the Setup/Earnings tabs", async ({ page }) => {
    await seedProviders(page, [makeProvider()]);
    await page.goto("/providers");

    await expect(page.getByText("Apple M3 Max").first()).toBeVisible();
    await expect(page.getByRole("link", { name: "Setup", exact: true })).toBeVisible();

    await page.getByRole("link", { name: "Earnings", exact: true }).click();
    await expect(page).toHaveURL(/\/providers\/earnings$/);
  });
});

test.describe("API keys", () => {
  test("creating a key adds it to the list", async ({ page }) => {
    await page.goto("/api-console");

    // Seeded existing key renders.
    await expect(page.getByText("Default key")).toBeVisible();

    await page.getByRole("button", { name: "New key" }).click();
    await page.getByPlaceholder("e.g. Production server").fill("My E2E Key");
    await page.getByRole("button", { name: "Create key" }).click();

    // One-time secret-reveal modal confirms the POST round-trip succeeded.
    await expect(page.getByText("Save your API key")).toBeVisible();
    await page.getByRole("button", { name: "Done" }).click();

    // After dismissing the modal, the new key is listed (refetch is mocked).
    await expect(page.getByText("My E2E Key")).toBeVisible();
  });
});

test.describe("chat", () => {
  test("sending a message renders the streamed assistant response", async ({ page }) => {
    await page.goto("/");

    const input = page.getByPlaceholder("Send a message...");
    await expect(input).toBeVisible();
    await input.fill("ping");
    await input.press("Enter");

    // The mocked SSE stream resolves to this content.
    await expect(page.getByText("Hello from the E2E mock")).toBeVisible({ timeout: 15_000 });
  });
});
