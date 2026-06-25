import {
  test,
  expect,
  SEED_MODEL,
  E2E_COORD_PUB_B64,
  makePrice,
  makeStats,
  makeLeaderboardEntry,
  seedPricing,
} from "./fixtures";

// Functional coverage for pages the shell suite only smoke-loaded (settings,
// stats, device-linking, models, earnings). Each drives real product behaviour
// against the route-mocked coordinator (see fixtures.ts), not just hydration.

test.describe("settings", () => {
  test("Test Connection reports a healthy coordinator", async ({ page }) => {
    await page.goto("/settings");

    await page.getByRole("button", { name: "Test Connection" }).click();
    await expect(page.getByText(/Connected — 0 providers online/)).toBeVisible();
  });

  test("enabling encryption surfaces the not-configured state", async ({ page }) => {
    // 503 is the coordinator's "sender encryption not configured" signal, which
    // the page maps to a friendly unavailable message (any other non-ok status
    // would render the raw error instead).
    await page.route("**/api/encryption-key", (route) => route.fulfill({ status: 503, body: "" }));
    await page.goto("/settings");

    await page.getByRole("checkbox").check();
    await expect(
      page.getByText("This coordinator has not configured sender encryption."),
    ).toBeVisible();
  });

  test("enabling encryption with a published key confirms kid", async ({ page }) => {
    await page.route("**/api/encryption-key", (route) =>
      route.fulfill({
        json: {
          kid: "abcd1234abcd1234",
          public_key: E2E_COORD_PUB_B64,
          algorithm: "x25519-nacl-box",
        },
      }),
    );
    await page.goto("/settings");

    await page.getByRole("checkbox").check();
    await expect(page.getByText("coordinator key kid=abcd1234abcd1234")).toBeVisible();
  });

  test("saving settings persists the coordinator URL", async ({ page }) => {
    await page.goto("/settings");

    const input = page.locator('input[type="text"]').first();
    await input.fill("https://coord-e2e.example");
    await page.getByRole("button", { name: "Save Settings" }).click();
    await expect(page.getByRole("button", { name: "Saved" })).toBeVisible();

    const stored = await page.evaluate(() =>
      localStorage.getItem("darkbloom_coordinator_url"),
    );
    expect(stored).toBe("https://coord-e2e.example");
  });
});

test.describe("stats", () => {
  test("renders the network hero stats from /api/stats", async ({ page }) => {
    await page.goto("/stats");

    await expect(page.getByText("Network Statistics")).toBeVisible();
    await expect(page.getByText("Tokens Served")).toBeVisible();
    await expect(page.getByText("Nodes Online")).toBeVisible();
    await expect(page.getByText("GB/s Bandwidth")).toBeVisible();
    // makeStats() seeds 6_500_000 total tokens → formatNumber → "6.5M".
    await expect(page.getByText("6.5M").first()).toBeVisible();
  });

  test("shows an error state and recovers on Retry", async ({ page }) => {
    // Fail the stats fetch until the error is on screen, then serve success and
    // drive Retry (the page polls, so a one-shot failure would be masked).
    let healthy = false;
    await page.route(/\/api\/stats(\?.*)?$/, (route) =>
      healthy
        ? route.fulfill({ json: makeStats() })
        : route.fulfill({ status: 500, json: { error: { message: "boom" } } }),
    );
    await page.goto("/stats");
    await expect(page.getByText("Failed to load platform stats")).toBeVisible();

    healthy = true;
    await page.getByRole("button", { name: "Retry" }).click();
    await expect(page.getByText("Tokens Served")).toBeVisible();
  });

  test("leaderboard tab renders rankings and network totals", async ({ page }) => {
    await page.goto("/stats");
    await page.getByRole("button", { name: "Leaderboard" }).click();

    await expect(page.getByText("Provider Earnings Leaderboard")).toBeVisible();
    await expect(page.getByText("Total earnings")).toBeVisible();
    // formatNumber(2_500_000) → "2.5M"; formatUSDFromMicro(5_000_000) → "$5.00".
    await expect(page.getByText("2.5M").first()).toBeVisible();
    await expect(page.getByText("$5.00").first()).toBeVisible();
    await expect(page.getByText(makeLeaderboardEntry().pseudonym as string).first()).toBeVisible();
  });
});

test.describe("device linking", () => {
  test("links a device with a valid code", async ({ page }) => {
    await page.goto("/link");

    await page.getByPlaceholder("XXXX-XXXX").fill("ABCD1234"); // formats to ABCD-1234
    await page.getByRole("button", { name: "Link Device" }).click();

    await expect(page.getByRole("heading", { name: "Device Linked!" })).toBeVisible();
  });

  test("surfaces an error for an invalid code", async ({ page }) => {
    await page.route("**/api/device/approve", (route) =>
      route.fulfill({
        status: 400,
        contentType: "application/json",
        body: JSON.stringify({ error: { message: "Invalid or expired code" } }),
      }),
    );
    await page.goto("/link");

    await page.getByPlaceholder("XXXX-XXXX").fill("ABCD1234");
    await page.getByRole("button", { name: "Link Device" }).click();

    await expect(page.getByText("Invalid or expired code")).toBeVisible();
  });
});

test.describe("models", () => {
  test("lists a model with its coordinator price", async ({ page }) => {
    await seedPricing(page, [makePrice(SEED_MODEL.id, 100_000, 300_000)]);
    await page.goto("/models");

    await expect(page.getByText("Available Models")).toBeVisible();
    await expect(page.getByRole("heading", { name: SEED_MODEL.id })).toBeVisible();
    await expect(page.getByText("$0.100 / $0.300").first()).toBeVisible();
  });
});

test.describe("earnings calculator", () => {
  test("computes earnings and the base-reward tier tracks the hardware", async ({ page }) => {
    await page.goto("/earn");

    await expect(page.getByText("Provider Earnings Calculator")).toBeVisible();
    await expect(page.getByText("Monthly net earnings")).toBeVisible();
    // Default MacBook Pro / M4 Max / 48GB with the seeded catalog model.
    await expect(page.getByText("$127").first()).toBeVisible();
    // The 48 GB tier (default M4 Max) has a deterministic $16.00 base-reward floor.
    await expect(page.getByText("$16.00").first()).toBeVisible();

    // Selecting the 64 GB tier flips the floor to $18.00 (FLOOR_TIERS math).
    await page.getByRole("button", { name: "64 GB", exact: true }).click();
    await expect(page.getByText("$18.00").first()).toBeVisible();
  });
});
