import { test, expect, CHAT_REPLY, SEED_VISION_MODEL, seedModels, chatSse } from "./fixtures";

// Deeper chat coverage beyond the single send/stop/model-switch flows: a
// multi-turn conversation, the new-chat + history-restore lifecycle, vision
// image upload, and graceful handling of a truncated stream.

// 1x1 transparent PNG (valid header) for the image-attach flow.
const PNG_1x1_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

test.describe("chat", () => {
  test("multi-turn conversation renders a reply per turn", async ({ page }) => {
    const bodies: Array<{ messages?: Array<{ role: string; content: string }> }> = [];
    await page.route("**/api/chat", async (route) => {
      bodies.push(JSON.parse(route.request().postData() || "{}"));
      await route.fulfill({
        status: 200,
        headers: { "content-type": "text/event-stream" },
        body: chatSse(CHAT_REPLY.split(" ").map((w, i) => (i === 0 ? w : ` ${w}`))),
      });
    });

    await page.goto("/");
    const input = page.getByPlaceholder("Send a message...");

    await input.fill("ping");
    await input.press("Enter");
    await expect(page.getByText(CHAT_REPLY)).toHaveCount(1);

    await input.fill("pong");
    await input.press("Enter");
    await expect(page.getByText(CHAT_REPLY)).toHaveCount(2);
    await expect(page.getByText("pong")).toBeVisible();

    expect(bodies.length).toBe(2);
    const secondTurn = bodies[1].messages ?? [];
    expect(secondTurn.some((m) => m.role === "user" && m.content === "ping")).toBe(true);
    expect(secondTurn.some((m) => m.role === "assistant" && m.content === CHAT_REPLY)).toBe(true);
    expect(secondTurn.some((m) => m.role === "user" && m.content === "pong")).toBe(true);
  });

  test("New chat starts a fresh thread and history restores the old one", async ({ page }) => {
    await page.goto("/");
    const input = page.getByPlaceholder("Send a message...");

    await input.fill("remember me");
    await input.press("Enter");
    await expect(page.getByText(CHAT_REPLY)).toHaveCount(1);

    await page.getByRole("button", { name: "New chat" }).click();
    // Fresh thread: the prior reply is gone from the main view.
    await expect(page.getByText(CHAT_REPLY)).toHaveCount(0);

    // The previous chat is in the sidebar (its title is the first message) —
    // clicking it restores the thread.
    await page.getByText("remember me").click();
    await expect(page.getByText(CHAT_REPLY)).toHaveCount(1);
  });

  test("attaching an image to a vision model sends and replies", async ({ page }) => {
    await seedModels(page, [SEED_VISION_MODEL]);
    await page.goto("/");

    // The attach control is gated on the model's vision capability.
    await expect(page.getByRole("button", { name: "Attach image" })).toBeVisible();
    await page.locator('input[type="file"]').setInputFiles({
      name: "pixel.png",
      mimeType: "image/png",
      buffer: Buffer.from(PNG_1x1_BASE64, "base64"),
    });
    // Thumbnail with a remove control confirms the file was accepted + encoded.
    await expect(page.getByRole("button", { name: "Remove image 1" })).toBeVisible();

    const input = page.getByPlaceholder("Send a message...");
    await input.fill("what is this?");
    await input.press("Enter");
    await expect(page.getByText(CHAT_REPLY)).toBeVisible();
  });

  test("a truncated stream (no [DONE]) keeps partial content without erroring", async ({ page }) => {
    await page.route("**/api/chat", (route) =>
      route.fulfill({
        status: 200,
        headers: { "content-type": "text/event-stream" },
        // One content chunk, then the body ends with NO `[DONE]`. The parser
        // must finish gracefully and preserve the partial text.
        body: `data: ${JSON.stringify({ choices: [{ delta: { content: "Partial answer" } }] })}\n\n`,
      }),
    );
    await page.goto("/");
    const input = page.getByPlaceholder("Send a message...");
    await input.fill("hello");
    await input.press("Enter");

    await expect(page.getByText("Partial answer")).toBeVisible();
    // Returned to idle (Send, not Stop) with no error bubble (the chat surfaces
    // failures as "... error ...", so a case-insensitive match is the real guard).
    await expect(page.getByRole("button", { name: "Send message" })).toBeVisible();
    await expect(page.getByText(/error/i)).toHaveCount(0);
  });

  test("verification panel toggles between simple and technical views", async ({ page }) => {
    await page.route("**/api/chat", (route) =>
      route.fulfill({
        status: 200,
        headers: {
          "content-type": "text/event-stream",
          "x-provider-trust-level": "hardware",
          "x-provider-mda-verified": "true",
          "x-provider-attested": "true",
          "x-provider-secure-enclave": "true",
          "x-provider-chip": "Apple M3 Max",
          "x-provider-serial": "C02XYZ123456",
        },
        body: chatSse(CHAT_REPLY.split(" ").map((w, i) => (i === 0 ? w : ` ${w}`))),
      }),
    );
    await page.goto("/");
    const input = page.getByPlaceholder("Send a message...");
    await input.fill("verify me");
    await input.press("Enter");
    await expect(page.getByText(CHAT_REPLY)).toBeVisible();

    await page.getByRole("button", { name: /Apple-verified hardware/ }).click();
    await expect(page.getByText("Security Guarantees")).toBeVisible();
    await page.getByRole("button", { name: "Technical" }).click();
    await expect(page.getByText("Provider Security Verification")).toBeVisible();
    await expect(page.getByText("C02XYZ123456")).toBeVisible();
    await page.getByRole("button", { name: "Simple" }).click();
    await expect(page.getByText("Security Guarantees")).toBeVisible();
  });
});
