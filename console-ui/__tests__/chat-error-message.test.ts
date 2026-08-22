import { describe, expect, it } from "vitest";
import { chatErrorMessage } from "@/lib/chat/errors";

// Copy mapping for upstream chat failures. The 402 cases are the regression:
// the console used to answer every payment error with "buy credits", including
// the ones buying credits cannot fix.
describe("chatErrorMessage", () => {
  const body = (message: string, code?: string) =>
    JSON.stringify({ error: { message, code } });

  it("explains self-route machine states from the error code", () => {
    expect(chatErrorMessage(503, body("...", "machine_offline"), { code: "machine_offline" }))
      .toContain("Your machine is offline");
    expect(chatErrorMessage(409, body("...", "no_linked_machine"), { code: "no_linked_machine" }))
      .toContain("No machine linked");
    expect(chatErrorMessage(429, body("...", "machine_busy"), { code: "machine_busy" }))
      .toContain("Your machine is busy");
  });

  it("surfaces the coordinator's 402 explanation instead of a blanket credits pitch", () => {
    const message =
      "your machine cannot serve this request right now (offline, model not loaded, or below a required capability) and your balance is too low for the paid fallback — start your Darkbloom node and load the model, or add funds at /billing";
    const out = chatErrorMessage(402, body(message, "insufficient_quota"), {
      message,
      code: "insufficient_quota",
    });
    expect(out).toContain("machine cannot serve this request");
    expect(out).toContain("add funds at /billing");
    expect(out.startsWith("Your machine")).toBe(true); // rendered as a sentence
  });

  it("keeps a spend-cap 402 pointed at the key, not at Billing", () => {
    const message =
      "API key spend limit reached (monthly cap $5.00, used $5.00) — raise this key's limit or use another key";
    const out = chatErrorMessage(402, body(message, "insufficient_quota"), {
      message,
      code: "insufficient_quota",
    });
    expect(out).toBe(message);
    expect(out).not.toContain("buy credits");
  });

  it("falls back to the credits pitch when the 402 carries no explanation", () => {
    expect(chatErrorMessage(402, "{}", {})).toBe(
      "Insufficient credits — buy credits in Billing to continue",
    );
  });

  it("maps a queue-timeout 503 to the busy-network copy", () => {
    const message = 'all providers for model "x" are at capacity (queue timeout)';
    expect(chatErrorMessage(503, body(message), { message })).toBe(
      "All providers are busy — please try again in a moment",
    );
  });

  it("falls back to the raw body when the error object has no message", () => {
    expect(chatErrorMessage(500, "upstream exploded", {})).toBe(
      "Request failed (500): upstream exploded",
    );
  });
});
