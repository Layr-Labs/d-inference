import { render, waitFor } from "@testing-library/react";
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";

// SEC-002 regression: the Earnings page sends a bearer token with its
// account-earnings fetch. That fetch must go to the build-time coordinator
// URL — a localStorage-poisoned `darkbloom_coordinator_url` must never
// receive the token.

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({
    ready: true,
    authenticated: true,
    login: vi.fn(),
    getAccessToken: vi.fn().mockResolvedValue("privy-access-token"),
  }),
}));

vi.mock("@/hooks/useToast", () => ({
  useToastStore: (selector: (s: { addToast: () => void }) => unknown) =>
    selector({ addToast: vi.fn() }),
}));

vi.mock("@/lib/google-analytics", () => ({
  trackEvent: vi.fn(),
}));

vi.mock("@/lib/api", () => ({
  fetchStripeStatus: vi.fn().mockResolvedValue({
    connected: false,
    payouts_enabled: false,
    requirements_due: [],
  }),
  startStripeOnboarding: vi.fn(),
  withdrawStripe: vi.fn(),
  fetchStripeWithdrawals: vi.fn().mockResolvedValue([]),
  computeStripeFeeUsd: vi.fn().mockReturnValue(0),
}));

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue({
    ok: true,
    status: 200,
    json: () =>
      Promise.resolve({
        account_id: "acct",
        earnings: [],
        total_micro_usd: 0,
        total_usd: "0.00",
        count: 0,
        recent_count: 0,
        history_limit: 100,
        available_balance_micro_usd: 0,
        available_balance_usd: "0.00",
        withdrawable_balance_micro_usd: 0,
        withdrawable_balance_usd: "0.00",
      }),
  });
  vi.stubGlobal("fetch", fetchMock);
  localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("EarningsContent coordinator URL pinning (SEC-002)", () => {
  it("ignores a poisoned localStorage coordinator URL", async () => {
    localStorage.setItem(
      "darkbloom_coordinator_url",
      "https://attacker.example.com"
    );

    const { default: EarningsContent } = await import(
      "@/app/providers/earnings/EarningsContent"
    );
    render(<EarningsContent />);

    await waitFor(() => expect(fetchMock).toHaveBeenCalled());

    const earningsCall = fetchMock.mock.calls.find((c) =>
      String(c[0]).includes("/v1/provider/account-earnings")
    );
    expect(earningsCall).toBeDefined();
    const url = String(earningsCall![0]);
    expect(url.startsWith("https://api.darkbloom.dev/")).toBe(true);
    expect(url).not.toContain("attacker.example.com");
  });
});
