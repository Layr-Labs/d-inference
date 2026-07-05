// User-facing copy for the Stripe payouts flow: maps backend error codes,
// withdrawal statuses, and withdraw responses to friendly messages.
//
// Backend error codes come from coordinator/api/stripe_withdraw.go and
// stripe_payouts.go via the { error: { type, message, code } } envelope,
// which lib/api/errors.ts parses into ApiError. Keep the code list here in
// sync with the coordinator handlers.

import { ApiError } from "@/lib/api";

// How the UI should react to a payout error, beyond showing the message.
export interface PayoutErrorPresentation {
  /** Backend error code ("" when unknown). */
  code: string;
  /** Friendly message for the toast. */
  message: string;
  /** Reload Stripe status - the account state changed server-side. */
  refreshStatus: boolean;
  /** Close the withdraw modal - retrying can't succeed until the account is fixed. */
  closeModal: boolean;
}

// Copy for withdraw-path error codes. Codes absent here fall through to the
// raw backend message.
const WITHDRAW_ERROR_COPY = new Map<string, Omit<PayoutErrorPresentation, "code">>([
  ["stripe_account_gone", {
    // The backend already auto-unlinked the account; after the status
    // refresh the card returns to its "Set up payouts" state.
    message: "Your Stripe account was closed, so we've unlinked it. You can set up payouts again below.",
    refreshStatus: true,
    closeModal: true,
  }],
  ["stripe_account_recreate_required", {
    // The backend flipped the account status to "restricted"; after the
    // status refresh the card shows the Action-needed branch, whose setup
    // button re-runs onboarding and recreates the account correctly.
    message: "Your payout account needs to be recreated to support payouts in your country. Re-run payout setup below to fix it.",
    refreshStatus: true,
    closeModal: true,
  }],
  ["instant_unavailable", {
    message: "Instant payouts need a debit card linked in Stripe. Use standard, or add a debit card.",
    refreshStatus: true,
    closeModal: false,
  }],
  ["insufficient_withdrawable", {
    message: "You can only withdraw earned funds. Purchased credits aren't withdrawable.",
    refreshStatus: false,
    closeModal: false,
  }],
  ["not_onboarded", {
    message: "Finish your payout setup first, then try withdrawing again.",
    refreshStatus: true,
    closeModal: true,
  }],
  ["stripe_error", {
    message: "Stripe couldn't process this right now - nothing was withdrawn. Try again in a few minutes.",
    refreshStatus: false,
    closeModal: false,
  }],
]);

// classifyWithdrawError maps a withdraw failure to friendly copy + follow-up
// actions. Unknown codes keep the raw backend message.
export function classifyWithdrawError(err: unknown): PayoutErrorPresentation {
  const code = err instanceof ApiError ? err.code : "";
  const raw = err instanceof Error ? err.message : String(err);
  const lower = raw.toLowerCase();

  // An UNCONFIRMED outcome (Stripe never answered - the transfer may still
  // complete) is deliberately NOT refunded: the withdrawal is on hold. This
  // must be checked before the refund-pending branch below, whose broader
  // "contact support" match would otherwise promise a refund that the
  // backend intentionally did not issue.
  if (code === "stripe_error" && (lower.includes("could not confirm") || lower.includes("couldn't confirm") || lower.includes("unconfirmed"))) {
    return {
      code,
      message: "We couldn't confirm this withdrawal with Stripe. It's on hold - nothing was refunded - and it will complete or be resolved automatically. Contact support if it doesn't update within 24 hours.",
      refreshStatus: false,
      closeModal: true,
    };
  }

  // A stripe_error whose backend message asks the user to contact support
  // means a refund is still pending - don't claim nothing was withdrawn.
  if (code === "stripe_error" && lower.includes("contact support")) {
    return {
      code,
      message: "Stripe couldn't process this withdrawal. The refund to your balance is pending - contact support if it doesn't appear shortly.",
      refreshStatus: false,
      closeModal: true,
    };
  }

  const copy = WITHDRAW_ERROR_COPY.get(code);
  if (copy) return { code, ...copy };
  return { code, message: raw || "Withdrawal failed.", refreshStatus: false, closeModal: false };
}

// classifyOnboardError maps an onboarding failure to friendly copy. The
// service-agreement / capability-approval detection (Stripe hasn't approved
// transfers-only for the platform in that country yet) is substring-based on
// the raw message and applies ONLY to the onboard path.
export function classifyOnboardError(err: unknown): PayoutErrorPresentation {
  const code = err instanceof ApiError ? err.code : "";
  const raw = err instanceof Error ? err.message : String(err);
  const lower = raw.toLowerCase();

  if (lower.includes("service agreement") || lower.includes("capabilit")) {
    return {
      code,
      message: "Payouts for your country are almost ready - we're finalizing support with Stripe. Please try again in a few days.",
      refreshStatus: false,
      closeModal: false,
    };
  }
  if (code === "stripe_account_gone") {
    return {
      code,
      message: "Your Stripe account was closed, so we've unlinked it. You can set up payouts again below.",
      refreshStatus: true,
      closeModal: false,
    };
  }
  if (code === "stripe_error") {
    return {
      code,
      message: "Stripe couldn't start onboarding right now. Try again in a few minutes.",
      refreshStatus: false,
      closeModal: false,
    };
  }
  return {
    code,
    message: `Stripe onboarding failed: ${raw || "unknown error"}`,
    refreshStatus: false,
    closeModal: false,
  };
}

// --- Withdraw success ---

// withdrawSuccessMessage builds the success toast from the withdraw
// response. Standard withdrawals deliver via Stripe's automatic daily payout
// in the user's local currency; instant delivers to the debit card. A
// "transferred" status on an instant withdrawal means the instant payout
// failed and fell back to the standard rail - the backend message explains
// (including whether the instant fee was refunded).
export function withdrawSuccessMessage(resp: {
  status: string;
  method: string;
  eta?: string;
  message?: string;
}): string {
  const eta = resp.eta ? ` (ETA ${resp.eta})` : "";
  if (resp.method === "instant") {
    if (resp.status === "submitted") {
      return `On its way - arriving on your debit card${eta}.`;
    }
    return resp.message || `On its way - funds will arrive via Stripe's standard daily payout${eta}.`;
  }
  // Standard: the coordinator's message is schedule-aware (daily in most
  // countries, weekly in Japan) - prefer it over a hard-coded cadence.
  if (resp.message) {
    const msg = resp.message.charAt(0).toUpperCase() + resp.message.slice(1);
    return `${msg}${eta}.`;
  }
  return `On its way - Stripe pays out to your bank in your local currency${eta}.`;
}

// --- Withdraw modal method copy ---

export const STANDARD_ETA = "1-3 business days";
export const INSTANT_ETA = "~30 minutes";

// standardEta returns the standard-method ETA for the account's country.
// Japan has no daily automatic payouts (the backend configures weekly sweeps
// there — see coordinator/billing setAutoPayoutSchedule), so the honest ETA
// is up to a week to the sweep plus the bank rail.
export function standardEta(country?: string): string {
  if (country?.trim().toUpperCase() === "JP") {
    return "up to 7-10 business days";
  }
  return STANDARD_ETA;
}

// methodExplainer returns the short helper line shown under the speed picker
// for the selected method. The instant fee terms come from the live status so
// the copy can't drift from the fee actually charged; the standard cadence is
// country-aware (weekly in Japan).
export function methodExplainer(
  method: "standard" | "instant",
  instantFeeBps: number,
  instantFeeMinUsd: number,
  country?: string,
): string {
  if (method === "instant") {
    const pct = (instantFeeBps / 100).toFixed(1).replace(/\.0$/, "");
    return `Arrives on your debit card in ~30 minutes. ${pct}% fee ($${instantFeeMinUsd.toFixed(2)} min).`;
  }
  if (country?.trim().toUpperCase() === "JP") {
    return "Funds are transferred right away and paid out by Stripe's weekly payout in Japan, arriving in your local currency. Typically up to 7-10 business days.";
  }
  return "Funds are transferred right away and paid out by Stripe's daily payout, arriving in your local currency. Typically 1-3 business days (some countries take up to one extra day).";
}

// --- Withdrawal history statuses ---

export interface WithdrawalStatusPresentation {
  /** Short label rendered in the row. */
  label: string;
  /** Longer explanation, rendered as a tooltip. */
  detail: string;
}

// withdrawalStatusPresentation maps a raw stripe_withdrawals status (plus the
// refunded flag) to a friendly label + tooltip for the history list.
export function withdrawalStatusPresentation(
  status: string,
  refunded?: boolean,
): WithdrawalStatusPresentation {
  switch (status) {
    case "pending":
      return { label: "Processing", detail: "Your withdrawal is being processed." };
    case "transferred":
      return {
        label: "On the way",
        detail: "Arrives via Stripe's daily payout in your local currency.",
      };
    case "paid":
      return { label: "Paid", detail: "Paid out to your bank or card." };
    case "failed":
      return refunded
        ? { label: "Failed - refunded", detail: "This withdrawal failed and was refunded to your balance." }
        : { label: "Failed - contact support", detail: "This withdrawal failed. Contact support to resolve it." };
    default:
      return { label: status, detail: "" };
  }
}
