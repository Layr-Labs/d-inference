import {
  test,
  expect,
  makeProvider,
  makeProvidersResponse,
  seedProviders,
  seedKeys,
  chatSse,
  CHAT_REPLY,
} from "./fixtures";

// Authenticated user flows, driven in a real browser against route-mocked
// coordinator APIs (see fixtures.ts). These exercise actual product behaviour —
// provider onboarding, API-key management, chat, and error/retry paths — not
// just the shell.

test.describe("provider onboarding", () => {
  test("empty fleet shows the onboarding state and 'Set up a provider' navigates", async ({ page }) => {
    await seedProviders(page, []); // explicit: don't rely on the fixture default
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

  test("editing a key applies a spend cap", async ({ page }) => {
    await page.goto("/api-console");
    await expect(page.getByText("Default key")).toBeVisible();

    await page.getByRole("button", { name: "Edit limits" }).click();
    await page.getByPlaceholder("Unlimited").fill("50");
    await page.getByRole("button", { name: "Save changes" }).click();

    // The card's usage bar now shows the cap (PATCH + refetch round-trip).
    await expect(page.getByText(/\$50(\.00)?/)).toBeVisible();
  });

  test("disabling a key flips the toggle to Enable", async ({ page }) => {
    await page.goto("/api-console");

    await expect(page.getByRole("button", { name: "Disable key" })).toBeVisible();
    await page.getByRole("button", { name: "Disable key" }).click();

    // After the PATCH + refetch the same row now offers re-enabling.
    await expect(page.getByRole("button", { name: "Enable key" })).toBeVisible();
  });

  test("rotating a key reveals a new secret", async ({ page }) => {
    await page.goto("/api-console");

    await page.getByRole("button", { name: "Rotate secret" }).click();
    await expect(page.getByText("Rotate API key")).toBeVisible(); // confirm dialog
    await page.getByRole("button", { name: "Rotate key" }).click();

    // Rotation returns a fresh once-only secret.
    await expect(page.getByText("Save your API key")).toBeVisible();
    await page.getByRole("button", { name: "Done" }).click();
  });

  test("revoking a key removes it from the list", async ({ page }) => {
    await page.goto("/api-console");
    await expect(page.getByText("Default key")).toBeVisible();

    // Open the confirm dialog (only the card icon matches before it opens).
    await page.getByRole("button", { name: "Revoke key" }).click();
    await expect(page.getByText("Revoke API key")).toBeVisible();
    // The dialog's confirm button is the last "Revoke key" in the DOM.
    await page.getByRole("button", { name: "Revoke key" }).last().click();

    // DELETE + refetch empties the list → empty state.
    await expect(page.getByText("No API keys yet")).toBeVisible();
    await expect(page.getByText("Default key")).toHaveCount(0);
  });

  test("empty key list shows the first-key prompt", async ({ page }) => {
    await seedKeys(page, []);
    await page.goto("/api-console");

    await expect(page.getByText("No API keys yet")).toBeVisible();
    await expect(page.getByRole("button", { name: /Create your first key/i })).toBeVisible();
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
    await expect(page.getByText(CHAT_REPLY)).toBeVisible({ timeout: 15_000 });
  });
});

test.describe("error + retry paths", () => {
  test("provider fleet load failure shows an error and recovers on retry", async ({ page }) => {
    // Keep failing through the initial load (the dashboard polls, so a one-shot
    // failure would be masked by the next poll). Swap to success only after the
    // error is on screen, then drive the Retry button.
    await page.route("**/api/me/providers", (route) =>
      route.fulfill({ status: 500, json: { error: { message: "boom" } } }),
    );

    await page.goto("/providers");
    await expect(page.getByText("Failed to load your fleet")).toBeVisible();

    await seedProviders(page, [makeProvider()]); // registered last → wins
    await page.getByRole("button", { name: "Retry" }).click();
    await expect(page.getByText("Apple M3 Max").first()).toBeVisible();
  });

  test("chat send failure surfaces an error, and retry recovers", async ({ page }) => {
    let calls = 0;
    await page.route("**/api/chat", (route) => {
      calls += 1;
      if (calls === 1) {
        return route.fulfill({
          status: 500,
          contentType: "application/json",
          body: JSON.stringify({ error: { message: "upstream boom" } }),
        });
      }
      return route.fulfill({
        status: 200,
        headers: { "content-type": "text/event-stream" },
        body: chatSse(["recovered ", "after ", "retry"]),
      });
    });

    await page.goto("/");
    const input = page.getByPlaceholder("Send a message...");
    await input.fill("ping");
    await input.press("Enter");

    // The failed turn renders an inline error bubble with a Retry affordance.
    await expect(page.getByText(/Error:/)).toBeVisible();
    await page.getByRole("button", { name: "Retry" }).click();

    // The retried turn streams successfully.
    await expect(page.getByText("recovered after retry")).toBeVisible({ timeout: 15_000 });
  });
});
