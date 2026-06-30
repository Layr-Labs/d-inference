import {
  test,
  expect,
  makeProvider,
  makeProvidersResponse,
  seedProviders,
  seedKeys,
  seedModels,
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

  test("switching the chat model updates the selector", async ({ page }) => {
    await seedModels(page, [
      { id: "model-a", object: "model", display_name: "Model Alpha", model_type: "chat" },
      { id: "model-b", object: "model", display_name: "Model Beta", model_type: "chat" },
    ]);
    await page.goto("/");

    // Models load after auth + key provisioning; the selector defaults to the
    // first model (store.setModels picks models[0] when none is selected).
    const selector = page.getByRole("button", { name: /Model Alpha/ });
    await expect(selector).toBeVisible();
    await selector.click();

    await page.getByRole("button", { name: /Model Beta/ }).click();

    // Selector now reflects the new model and no longer shows the old one.
    await expect(page.getByRole("button", { name: /Model Beta/ })).toBeVisible();
    await expect(page.getByRole("button", { name: /Model Alpha/ })).toHaveCount(0);
  });

  test("stop halts an in-flight generation", async ({ page }) => {
    // Hold the chat request open so the generation stays in-flight; the client
    // aborts it on Stop (the handler is abandoned when the page closes).
    await page.route("**/api/chat", async (route) => {
      await new Promise((r) => setTimeout(r, 15_000));
      await route.abort().catch(() => {});
    });

    await page.goto("/");
    const input = page.getByPlaceholder("Send a message...");
    await input.fill("ping");
    await input.press("Enter");

    // Streaming → the composer shows Stop.
    const stop = page.getByRole("button", { name: "Stop generating" });
    await expect(stop).toBeVisible();
    await stop.click();

    // Cancelled → composer returns to the idle Send state, no error bubble.
    await expect(page.getByRole("button", { name: "Send message" })).toBeVisible();
    await expect(page.getByText(/Error:/)).toHaveCount(0);
  });
});

test.describe("invite codes", () => {
  test("redeeming a valid code credits the account", async ({ page }) => {
    await page.route("**/api/invite/redeem", (route) =>
      route.fulfill({ json: { credited_usd: "5.00", balance_usd: "17.34" } }),
    );
    await page.goto("/billing");

    await page.getByPlaceholder("INV-XXXXXXXX").fill("INV-TEST1234");
    await page.getByRole("button", { name: "Redeem" }).click();

    await expect(page.getByText(/credited to your account/)).toBeVisible();
  });

  test("an invalid code surfaces an error", async ({ page }) => {
    await page.route("**/api/invite/redeem", (route) =>
      route.fulfill({
        status: 400,
        contentType: "application/json",
        body: JSON.stringify({ error: { message: "Invalid invite code" } }),
      }),
    );
    await page.goto("/billing");

    await page.getByPlaceholder("INV-XXXXXXXX").fill("INV-BADCODE0");
    await page.getByRole("button", { name: "Redeem" }).click();

    await expect(page.getByText("Invalid invite code")).toBeVisible();
  });
});

test.describe("billing", () => {
  test("shows the balance and completes an add-funds checkout", async ({ page }) => {
    await page.goto("/billing");

    // Balance from the mocked /api/payments/balance.
    await expect(page.getByText(/12\.34/).first()).toBeVisible();

    await page.getByRole("button", { name: "Buy Credits" }).click();
    await page.getByRole("button", { name: "Continue" }).click();

    // The mocked checkout redirects back with the success flag, which the page
    // detects and surfaces as a success toast.
    await expect(page.getByText("Payment successful!")).toBeVisible();
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

test.describe("page resilience", () => {
  // Regression for the crash this suite first surfaced: a malformed pricing
  // payload broke buildPricingLookup on both /models and /earn. The two pages
  // fail differently, so we assert against both mechanisms:
  //   - /models calls buildPricingLookup during render → a throw trips the ROOT
  //     error boundary, replacing the shell (the Chat link disappears).
  //   - /earn calls it inside a fetch .then() → a throw is an unhandled
  //     rejection (no boundary), so we also capture page errors/rejections.
  // Two malformed shapes are covered: a missing `prices` (catches the original
  // crash / a deleted guard) and a non-array `prices` (specifically pins the
  // Array.isArray guard — a weaker `?? []` would still throw here).
  const MALFORMED_PRICING: { label: string; body: unknown }[] = [
    { label: "missing prices", body: {} },
    { label: "non-array prices", body: { prices: {} } },
  ];
  for (const route of ["/models", "/earn"]) {
    for (const { label, body } of MALFORMED_PRICING) {
      test(`${route} survives a malformed pricing payload (${label})`, async ({ page }) => {
        const pageErrors: string[] = [];
        page.on("pageerror", (e) => pageErrors.push(e.message));
        await page.addInitScript(() => {
          const w = window as unknown as { __e2eErrors: string[] };
          w.__e2eErrors = [];
          window.addEventListener("unhandledrejection", (ev) =>
            w.__e2eErrors.push(String((ev as PromiseRejectionEvent).reason)),
          );
          window.addEventListener("error", (ev) => w.__e2eErrors.push(String(ev.message)));
        });

        await page.route("**/api/pricing", (r) => r.fulfill({ json: body }));
        await page.goto(route);
        await page.waitForLoadState("networkidle"); // let the pricing fetch resolve

        // Shell intact (no root error boundary).
        await expect(page.getByRole("link", { name: "Chat" }).first()).toBeVisible();
        await expect(page.getByText("Something went wrong")).toHaveCount(0);

        // No pricing-shape crash surfaced (render throw OR async rejection).
        const crashRe = /is not iterable|reading 'map'|is not a function/i;
        await expect
          .poll(async () => {
            const winErrors = await page.evaluate(
              () => (window as unknown as { __e2eErrors?: string[] }).__e2eErrors ?? [],
            );
            return [...pageErrors, ...winErrors].join("\n");
          })
          .not.toMatch(crashRe);
      });
    }
  }
});
