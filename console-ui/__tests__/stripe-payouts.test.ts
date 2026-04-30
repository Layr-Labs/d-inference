import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  computeStripeFeeUsd,
  fetchStripeStatus,
  startStripeOnboarding,
  withdrawStripe,
  fetchStripeWithdrawals,
} from "@/lib/api";

// Stripe Payouts client tests. These cover:
//   * Fee math (must mirror billing.FeeForMethodMicroUSD on the server side)
//   * Each API client function calls the right proxy URL with the right body
//   * Error responses are surfaced cleanly so the UI can show a toast

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
    headers: new Headers(),
  } as unknown as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);

  const store: Record<string, string> = {};
  vi.stubGlobal("localStorage", {
    getItem: (k: string) => store[k] ?? null,
    setItem: (k: string, v: string) => {
      store[k] = v;
    },
    removeItem: (k: string) => {
      delete store[k];
    },
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ---------------------------------------------------------------------------
// computeStripeFeeUsd
//
// This formula MUST stay in lockstep with billing.FeeForMethodMicroUSD on the
// server side. If you change one, change the other and update both test
// suites. Source of truth: coordinator/internal/billing/stripe_connect.go.
// ---------------------------------------------------------------------------

describe("computeStripeFeeUsd", () => {
  it("returns 0 for standard payouts", () => {
    expect(computeStripeFeeUsd(100, "standard")).toBe(0);
    expect(computeStripeFeeUsd(0.01, "standard")).toBe(0);
  });

  it("returns 0 for zero or negative amounts", () => {
    expect(computeStripeFeeUsd(0, "instant")).toBe(0);
    expect(computeStripeFeeUsd(-5, "instant")).toBe(0);
  });

  it("snaps to the $0.50 floor for small instant payouts", () => {
    // 1.5% of $5 = $0.075 → snaps to $0.50.
    expect(computeStripeFeeUsd(5, "instant")).toBe(0.5);
    // Right at the threshold ($33.33 → 1.5% = $0.499 → snaps to $0.50).
    expect(computeStripeFeeUsd(33, "instant")).toBe(0.5);
  });

  it("applies 1.5% above the floor", () => {
    expect(computeStripeFeeUsd(50, "instant")).toBe(0.75);
    expect(computeStripeFeeUsd(100, "instant")).toBe(1.5);
    expect(computeStripeFeeUsd(1000, "instant")).toBe(15);
  });

  it("respects custom bps and floor passed in via status", () => {
    // 2% with $1 floor
    expect(computeStripeFeeUsd(10, "instant", 200, 1)).toBe(1);   // 2% of $10 = $0.20 → snaps to $1
    expect(computeStripeFeeUsd(100, "instant", 200, 1)).toBe(2);  // 2% of $100 = $2 (above floor)
  });
});

// ---------------------------------------------------------------------------
// fetchStripeStatus
// ---------------------------------------------------------------------------

describe("fetchStripeStatus", () => {
  it("calls /api/payments/stripe/status without refresh by default", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({
      configured: true, has_account: true, status: "ready",
    }));
    const s = await fetchStripeStatus();
    expect(fetchMock).toHaveBeenCalledWith("/api/payments/stripe/status", expect.any(Object));
    expect(s.status).toBe("ready");
  });

  it("appends ?refresh=1 when called with refresh=true", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ configured: true, has_account: true, status: "ready" }));
    await fetchStripeStatus(true);
    expect(fetchMock).toHaveBeenCalledWith("/api/payments/stripe/status?refresh=1", expect.any(Object));
  });

  it("throws on non-2xx responses", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 500));
    await expect(fetchStripeStatus()).rejects.toThrow(/500/);
  });
});

// ---------------------------------------------------------------------------
// startStripeOnboarding
// ---------------------------------------------------------------------------

describe("startStripeOnboarding", () => {
  it("POSTs return_url to /api/payments/stripe/onboard", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({
      url: "https://connect.stripe.com/setup/abc",
      stripe_account_id: "acct_x",
      status: "pending",
    }));

    const resp = await startStripeOnboarding("https://app.test/billing?stripe_return=1");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, opts] = fetchMock.mock.calls[0];
    expect(opts.method).toBe("POST");
    expect(JSON.parse(opts.body)).toEqual({ return_url: "https://app.test/billing?stripe_return=1" });
    expect(resp.url).toContain("connect.stripe.com");
  });

  it("surfaces server error message when present", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: { message: "Stripe is down" } }, 502));
    await expect(startStripeOnboarding()).rejects.toThrow(/Stripe is down/);
  });
});

// ---------------------------------------------------------------------------
// withdrawStripe
// ---------------------------------------------------------------------------

describe("withdrawStripe", () => {
  it("POSTs amount and method to /api/payments/withdraw/stripe", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({
      status: "submitted",
      withdrawal_id: "wd-1",
      transfer_id: "tr_1",
      payout_id: "po_1",
      amount_usd: "10.00",
      fee_usd: "0.50",
      net_usd: "9.50",
      method: "instant",
      eta: "~30 minutes",
      balance_micro_usd: 0,
    }));
    const resp = await withdrawStripe("10.00", "instant");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/payments/withdraw/stripe");
    expect(JSON.parse(opts.body)).toEqual({ amount_usd: "10.00", method: "instant" });
    expect(resp.fee_usd).toBe("0.50");
    expect(resp.net_usd).toBe("9.50");
  });

  it("surfaces insufficient_funds error", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({
      error: { type: "insufficient_funds", message: "insufficient balance" },
    }, 400));
    await expect(withdrawStripe("10.00", "standard")).rejects.toThrow(/insufficient balance/);
  });

  it("surfaces instant_unavailable error", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({
      error: { type: "instant_unavailable", message: "instant payouts require a debit card destination" },
    }, 400));
    await expect(withdrawStripe("10.00", "instant")).rejects.toThrow(/debit card/);
  });
});

// ---------------------------------------------------------------------------
// fetchStripeWithdrawals
// ---------------------------------------------------------------------------

describe("fetchStripeWithdrawals", () => {
  it("returns the withdrawals array, default limit=20", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({
      withdrawals: [
        { id: "wd-1", account_id: "a", stripe_account_id: "acct_x", amount_micro_usd: 5_000_000, fee_micro_usd: 0, net_micro_usd: 5_000_000, method: "standard", status: "paid", created_at: "", updated_at: "" },
      ],
    }));
    const wds = await fetchStripeWithdrawals();
    expect(fetchMock).toHaveBeenCalledWith("/api/payments/stripe/withdrawals?limit=20", expect.any(Object));
    expect(wds).toHaveLength(1);
    expect(wds[0].id).toBe("wd-1");
  });

  it("returns [] when the response has no withdrawals key", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}));
    const wds = await fetchStripeWithdrawals();
    expect(wds).toEqual([]);
  });

  it("respects custom limit", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ withdrawals: [] }));
    await fetchStripeWithdrawals(5);
    expect(fetchMock).toHaveBeenCalledWith("/api/payments/stripe/withdrawals?limit=5", expect.any(Object));
  });
});
