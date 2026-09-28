import { describe, expect, it } from "vitest";
import { chatErrorMessage } from "./errors";

describe("promotional token exhaustion", () => {
  it("preserves the model-specific explanation instead of the generic billing error", () => {
    const message = "Your free tokens for Bonsai 2 are exhausted and your paid balance is too low. Add credits in Billing.";
    expect(chatErrorMessage(402, message, "free_tokens_exhausted")).toBe(message);
    expect(chatErrorMessage(402, "Lower max_tokens or add credits.", "promotion_balance_required")).toBe("Lower max_tokens or add credits.");
  });
  it("retains the existing ordinary insufficient-credit and other-model errors", () => {
    expect(chatErrorMessage(402, "low balance", "insufficient_quota")).toBe("Insufficient credits — buy credits in Billing to continue");
    expect(chatErrorMessage(400, "invalid model")).toBe("Request failed (400): invalid model");
  });
});
