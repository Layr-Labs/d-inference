import { describe, it, expect } from "vitest";
import { ApiError } from "@/lib/api";
import {
  classifyWithdrawError,
  classifyOnboardError,
  classifyDashboardError,
  withdrawSuccessMessage,
  methodExplainer,
  standardEta,
  withdrawalStatusPresentation,
  STANDARD_ETA,
  INSTANT_ETA,
} from "./payout-copy";

// Error-code literals shared across cases (mirrors coordinator error types).
const STRIPE_ERROR = "stripe_error";
const TRANSFERRED = "transferred";
const STANDARD = "standard";
const INSTANT = "instant";
const NETWORK_DOWN = "network down";
const STANDARD_ETA_TEXT = "1-3 business days";

describe("classifyWithdrawError", () => {
  it("stripe_account_gone: friendly unlink message, refresh + close modal", () => {
    const p = classifyWithdrawError(new ApiError("your Stripe payout account no longer exists", "stripe_account_gone", 409));
    expect(p.message).toContain("Your Stripe account was closed, so we've unlinked it");
    expect(p.refreshStatus).toBe(true);
    expect(p.closeModal).toBe(true);
  });

  it("stripe_account_recreate_required: recreate message, refresh + close modal", () => {
    const p = classifyWithdrawError(new ApiError("can't receive transfers", "stripe_account_recreate_required", 409));
    expect(p.message).toContain("needs to be recreated to support payouts in your country");
    expect(p.refreshStatus).toBe(true);
    expect(p.closeModal).toBe(true);
  });

  it("instant_unavailable: debit card guidance, keeps the modal open", () => {
    const p = classifyWithdrawError(new ApiError("instant payouts require a debit card", "instant_unavailable", 400));
    expect(p.message).toBe("Instant payouts need a debit card linked in Stripe. Use standard, or add a debit card.");
    expect(p.closeModal).toBe(false);
  });

  it("insufficient_withdrawable: earned-funds-only message", () => {
    const p = classifyWithdrawError(new ApiError("insufficient withdrawable balance", "insufficient_withdrawable", 400));
    expect(p.message).toBe("You can only withdraw earned funds. Purchased credits aren't withdrawable.");
    expect(p.refreshStatus).toBe(false);
    expect(p.closeModal).toBe(false);
  });

  it("not_onboarded: finish setup first", () => {
    const p = classifyWithdrawError(new ApiError("link your bank first", "not_onboarded", 403));
    expect(p.message).toBe("Finish your payout setup first, then try withdrawing again.");
    expect(p.closeModal).toBe(true);
  });

  it("stripe_error: transient nothing-was-withdrawn message", () => {
    const p = classifyWithdrawError(new ApiError("could not verify your payout account with Stripe", STRIPE_ERROR, 502));
    expect(p.message).toBe("Stripe couldn't process this right now - nothing was withdrawn. Try again in a few minutes.");
  });

  it("stripe_error schedule-heal failure gets the same transient treatment", () => {
    const p = classifyWithdrawError(new ApiError("could not enable automatic payouts on your account - try again shortly", STRIPE_ERROR, 502));
    expect(p.message).toBe("Stripe couldn't process this right now - nothing was withdrawn. Try again in a few minutes.");
  });

  it("stripe_error with a pending refund does NOT claim nothing was withdrawn", () => {
    const p = classifyWithdrawError(new ApiError(
      "failed to transfer funds (the refund to your balance is pending - contact support if it doesn't appear shortly): boom",
      STRIPE_ERROR, 502,
    ));
    expect(p.message).toContain("refund to your balance is pending");
    expect(p.message).toContain("contact support");
    expect(p.message).not.toContain("nothing was withdrawn");
  });

  it("unconfirmed transfer (on hold, deliberately NOT refunded) never promises a refund", () => {
    // Backend message for the ambiguous-outcome path: contains BOTH
    // "couldn't confirm" and "contact support" - the unconfirmed branch
    // must win over the refund-pending branch.
    const p = classifyWithdrawError(new ApiError(
      "we couldn't confirm the transfer with Stripe - your withdrawal is on hold and nothing was refunded; it will complete or be resolved automatically, contact support if it doesn't update within 24 hours",
      STRIPE_ERROR, 502,
    ));
    expect(p.message).toContain("on hold");
    expect(p.message).toContain("nothing was refunded");
    expect(p.message).not.toContain("refund to your balance is pending");
    expect(p.closeModal).toBe(true);
  });

  it("unknown codes keep the raw backend message", () => {
    const p = classifyWithdrawError(new ApiError("minimum withdrawal is $1.00", "invalid_request_error", 400));
    expect(p.message).toBe("minimum withdrawal is $1.00");
    expect(p.refreshStatus).toBe(false);
    expect(p.closeModal).toBe(false);
  });

  it("does NOT apply the onboard-only service-agreement detection", () => {
    const p = classifyWithdrawError(new Error("service agreement mismatch"));
    expect(p.message).toBe("service agreement mismatch");
  });

  it("handles plain Errors without a code", () => {
    const p = classifyWithdrawError(new Error(NETWORK_DOWN));
    expect(p.message).toBe(NETWORK_DOWN);
    expect(p.code).toBe("");
  });
});

describe("classifyOnboardError", () => {
  it("detects service-agreement onboarding failures by substring", () => {
    const p = classifyOnboardError(new ApiError("recipient service agreement not enabled for platform", STRIPE_ERROR, 502));
    expect(p.message).toBe("Payouts for your country are almost ready - we're finalizing support with Stripe. Please try again in a few days.");
  });

  it("detects capability-approval failures case-insensitively", () => {
    const p = classifyOnboardError(new ApiError("The Capability transfers has not been approved", STRIPE_ERROR, 502));
    expect(p.message).toContain("almost ready");
  });

  it("stripe_account_gone: unlink message + status refresh", () => {
    const p = classifyOnboardError(new ApiError("account no longer exists", "stripe_account_gone", 409));
    expect(p.message).toContain("unlinked");
    expect(p.refreshStatus).toBe(true);
  });

  it("other stripe_error: friendly transient onboarding message", () => {
    const p = classifyOnboardError(new ApiError("rate limited", STRIPE_ERROR, 502));
    expect(p.message).toBe("Stripe couldn't start onboarding right now. Try again in a few minutes.");
  });

  it("unknown errors keep the onboarding-failed prefix", () => {
    const p = classifyOnboardError(new Error(NETWORK_DOWN));
    expect(p.message).toBe("Stripe onboarding failed: network down");
  });
});

describe("classifyDashboardError", () => {
  it("account_gone: unlink message + status refresh", () => {
    const p = classifyDashboardError(new ApiError("your Stripe account no longer exists", "account_gone", 409));
    expect(p.message).toContain("Your Stripe account was closed, so we've unlinked it");
    expect(p.refreshStatus).toBe(true);
  });

  it("no_stripe_account: points at linking a bank first, refreshes the card branch", () => {
    const p = classifyDashboardError(new ApiError("no Stripe payout account on file", "no_stripe_account", 409));
    expect(p.message).toBe("Link a bank account first, then you can manage it in Stripe.");
    expect(p.refreshStatus).toBe(true);
  });

  it("stripe_error: friendly transient message, no unlink implied", () => {
    const p = classifyDashboardError(new ApiError("stripe 500: down", STRIPE_ERROR, 502));
    expect(p.message).toBe("Stripe couldn't open your dashboard right now. Try again in a few minutes.");
    expect(p.refreshStatus).toBe(false);
  });

  it("billing_error: same transient message when payouts aren't configured", () => {
    const p = classifyDashboardError(new ApiError("Stripe Payouts not configured", "billing_error", 503));
    expect(p.message).toBe("Stripe couldn't open your dashboard right now. Try again in a few minutes.");
  });

  it("unknown errors keep the raw message", () => {
    const p = classifyDashboardError(new Error(NETWORK_DOWN));
    expect(p.message).toBe(NETWORK_DOWN);
    expect(p.refreshStatus).toBe(false);
  });
});

describe("withdrawSuccessMessage", () => {
  it("standard: daily payout in local currency with ETA", () => {
    expect(withdrawSuccessMessage({ status: TRANSFERRED, method: STANDARD, eta: STANDARD_ETA_TEXT }))
      .toBe("On its way - Stripe pays out daily to your bank in your local currency (ETA 1-3 business days).");
  });

  it("standard without an ETA omits the parenthetical", () => {
    expect(withdrawSuccessMessage({ status: TRANSFERRED, method: STANDARD }))
      .toBe("On its way - Stripe pays out daily to your bank in your local currency.");
  });

  it("instant submitted: debit card with ETA", () => {
    expect(withdrawSuccessMessage({ status: "submitted", method: INSTANT, eta: "~30 minutes" }))
      .toBe("On its way - arriving on your debit card (ETA ~30 minutes).");
  });

  it("instant fallback to standard rail surfaces the backend message", () => {
    const msg = "instant payout unavailable - the fee was refunded and funds will arrive via the standard daily payout";
    expect(withdrawSuccessMessage({ status: TRANSFERRED, method: INSTANT, message: msg })).toBe(msg);
  });

  it("instant fallback without a backend message uses the standard-rail copy", () => {
    expect(withdrawSuccessMessage({ status: TRANSFERRED, method: INSTANT }))
      .toBe("On its way - funds will arrive via Stripe's standard daily payout.");
  });
});

describe("methodExplainer", () => {
  it("standard: daily payout + local currency + 1-3 business days", () => {
    const text = methodExplainer(STANDARD, 150, 0.5);
    expect(text).toContain("daily payout");
    expect(text).toContain("local currency");
    expect(text).toContain(STANDARD_ETA_TEXT);
    expect(text).toContain("one extra day");
  });

  it("instant: ~30 minutes with the live fee terms", () => {
    expect(methodExplainer(INSTANT, 150, 0.5))
      .toBe("Arrives on your debit card in ~30 minutes. 1.5% fee ($0.50 min).");
  });

  it("eta constants match the coordinator's etaForMethod", () => {
    expect(STANDARD_ETA).toBe(STANDARD_ETA_TEXT);
    expect(INSTANT_ETA).toBe("~30 minutes");
  });
});

describe("withdrawalStatusPresentation", () => {
  it("pending -> Processing", () => {
    expect(withdrawalStatusPresentation("pending").label).toBe("Processing");
  });

  it("transferred -> On the way, via daily payout", () => {
    const p = withdrawalStatusPresentation("transferred");
    expect(p.label).toBe("On the way");
    expect(p.detail).toContain("daily payout");
  });

  it("paid -> Paid", () => {
    expect(withdrawalStatusPresentation("paid").label).toBe("Paid");
  });

  it("failed + refunded -> refunded to balance", () => {
    const p = withdrawalStatusPresentation("failed", true);
    expect(p.label).toBe("Failed - refunded");
    expect(p.detail).toContain("refunded to your balance");
  });

  it("failed without refund -> contact support", () => {
    const p = withdrawalStatusPresentation("failed", false);
    expect(p.label).toBe("Failed - contact support");
  });

  it("unknown statuses pass through as the label", () => {
    expect(withdrawalStatusPresentation("weird").label).toBe("weird");
  });
});

describe("Japan weekly payout copy", () => {
  it("standardEta reports the weekly cadence for JP and the default elsewhere", () => {
    expect(standardEta("JP")).toBe("up to 7-10 business days");
    expect(standardEta("jp")).toBe("up to 7-10 business days");
    expect(standardEta("DE")).toBe("1-3 business days");
    expect(standardEta(undefined)).toBe("1-3 business days");
  });

  it("methodExplainer mentions the weekly schedule for JP standard withdrawals", () => {
    expect(methodExplainer("standard", 150, 0.5, "JP")).toContain("weekly payout in Japan");
    expect(methodExplainer("standard", 150, 0.5, "US")).toContain("daily payout");
    // Instant copy is country-independent.
    expect(methodExplainer("instant", 150, 0.5, "JP")).toContain("debit card");
  });
});
