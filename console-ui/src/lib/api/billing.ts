import { proxyHeaders } from "../http/proxy-client";
import { apiErrorFromBody } from "./errors";
import type {
  BalanceResponse,
  UsageEntry,
  StripeCheckoutResponse,
  StripeStatus,
  StripeOnboardResponse,
  StripeDashboardLinkResponse,
  StripeWithdrawResponse,
  StripeWithdrawal,
} from "./types";

export async function fetchBalance(): Promise<BalanceResponse> {
  const res = await fetch("/api/payments/balance", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch balance: ${res.status}`);
  return res.json();
}

export async function fetchUsage(): Promise<UsageEntry[]> {
  const res = await fetch("/api/payments/usage", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch usage: ${res.status}`);
  const data = await res.json();
  return data.usage || data;
}

export async function createStripeCheckout(amountUsd: string, email?: string): Promise<StripeCheckoutResponse> {
  const res = await fetch("/api/payments/stripe/checkout", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ amount_usd: amountUsd, ...(email ? { email } : {}) }),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data?.error?.message || data?.error || `Checkout failed (${res.status})`);
  }
  return res.json();
}

// --- Stripe Payouts (Connect Express) ---
//
// All Stripe Payouts endpoints require a Privy session — no API-key access.
// The proxy routes fall back to the privy-token cookie when no Authorization
// header is present, so the browser-side fetch needs no extra plumbing.

export async function fetchStripeStatus(refresh = false): Promise<StripeStatus> {
  const url = refresh ? "/api/payments/stripe/status?refresh=1" : "/api/payments/stripe/status";
  const res = await fetch(url, { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch Stripe status: ${res.status}`);
  return res.json();
}

export async function startStripeOnboarding(returnURL?: string, country?: string): Promise<StripeOnboardResponse> {
  const res = await fetch("/api/payments/stripe/onboard", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ return_url: returnURL, ...(country ? { country } : {}) }),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw apiErrorFromBody(data, res.status, `Stripe onboarding failed (${res.status})`);
  }
  return res.json();
}

// Mint a single-use Stripe Express Dashboard login link. This is the only way
// an onboarded user can change the bank account or debit card their payouts
// land in — the onboarding link only collects outstanding requirements, and
// Stripe forbids account_update links for Express accounts.
export async function createStripeDashboardLink(): Promise<StripeDashboardLinkResponse> {
  const res = await fetch("/api/payments/stripe/dashboard", {
    method: "POST",
    headers: proxyHeaders(),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw apiErrorFromBody(data, res.status, `Couldn't open your Stripe dashboard (${res.status})`);
  }
  return res.json();
}

export async function withdrawStripe(amountUsd: string, method: "standard" | "instant"): Promise<StripeWithdrawResponse> {
  const res = await fetch("/api/payments/withdraw/stripe", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ amount_usd: amountUsd, method }),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw apiErrorFromBody(data, res.status, `Withdrawal failed (${res.status})`);
  }
  return res.json();
}

export async function fetchStripeWithdrawals(limit = 20): Promise<StripeWithdrawal[]> {
  const res = await fetch(`/api/payments/stripe/withdrawals?limit=${limit}`, { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch withdrawals: ${res.status}`);
  const data = await res.json();
  return data.withdrawals || [];
}

// Detach the linked Stripe Connect account so a fresh one can be onboarded.
// Escape hatch for wedged accounts (closed on Stripe, stuck onboarding,
// wrong country). In-flight withdrawals are unaffected.
export async function unlinkStripeAccount(): Promise<{ unlinked: boolean }> {
  const res = await fetch("/api/payments/stripe/account", {
    method: "DELETE",
    headers: proxyHeaders(),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw apiErrorFromBody(data, res.status, `Unlink failed (${res.status})`);
  }
  return res.json();
}

// computeStripeFeeUsd mirrors billing.FeeForMethodMicroUSD on the server so
// the UI can preview the fee without a round-trip. Keep these formulas in
// lockstep — see coordinator/internal/billing/stripe_connect.go.
//
// All math is done in integer micro-USD (matching the server) to avoid
// floating-point drift on amounts near the floor boundary; only the final
// result is converted back to USD for display.
export function computeStripeFeeUsd(amountUsd: number, method: "standard" | "instant", instantFeeBps = 150, instantFeeMinUsd = 0.5): number {
  if (method !== "instant" || amountUsd <= 0) return 0;
  const grossMicro = Math.round(amountUsd * 1_000_000);
  const minMicro = Math.round(instantFeeMinUsd * 1_000_000);
  const pctMicro = Math.floor((grossMicro * instantFeeBps) / 10_000);
  return Math.max(pctMicro, minMicro) / 1_000_000;
}
