// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, cleanup } from "@testing-library/react";
import { useEffect, type ReactNode } from "react";

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({
    ready: true,
    authenticated: true,
    login: vi.fn(),
    getAccessToken: vi.fn().mockResolvedValue("tok"),
  }),
}));

vi.mock("@/hooks/useToast", () => ({
  useToastStore: (selector: (s: { addToast: () => void }) => unknown) =>
    selector({ addToast: vi.fn() }),
}));

// Run the fetch once on mount, no interval.
vi.mock("@/hooks/useVisiblePolling", () => ({
  useVisiblePolling: (cb: () => void) => {
    // eslint-disable-next-line react-hooks/exhaustive-deps
    useEffect(() => { cb(); }, []);
  },
}));

vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

vi.mock("@/components/payouts", () => ({
  PayoutCoverageNotice: () => null,
  PayoutModal: () => null,
  StripeWithdrawModal: () => null,
  StripePayoutsCard: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
  useStripePayouts: () => ({
    status: null,
    withdrawals: [],
    withdrawConfirmationPending: false,
    onboardLoading: false,
    selectedCountry: "US",
    setSelectedCountry: vi.fn(),
    onboard: vi.fn(),
    unlink: vi.fn(),
    unlinkLoading: false,
    openDashboard: vi.fn(),
    dashboardLoading: false,
    openWithdraw: vi.fn(),
    withdrawOpen: false,
    setWithdrawOpen: vi.fn(),
    withdrawLoading: false,
    withdrawQuote: null,
    withdrawAmount: "",
    setWithdrawAmount: vi.fn(),
    withdrawMethod: "bank",
    setWithdrawMethod: vi.fn(),
    withdraw: vi.fn(),
  }),
}));

import EarningsContent from "./EarningsContent";

function earning(id: number, model: string, micro: number) {
  return {
    id,
    provider_id: "node",
    provider_key: "key",
    job_id: `job-${id}`,
    model,
    amount_micro_usd: micro,
    prompt_tokens: 10,
    completion_tokens: 5,
    created_at: "2026-10-01T00:00:00Z",
  };
}

function response(overrides: Record<string, unknown> = {}) {
  return {
    account_id: "acct",
    earnings: [earning(1, "mlx-community/Qwen3-8B", 1_000_000)],
    total_micro_usd: 3_000_000,
    total_usd: "3.000000",
    count: 4,
    recent_count: 1,
    history_limit: 100,
    available_balance_micro_usd: 3_000_000,
    available_balance_usd: "3.000000",
    withdrawable_balance_micro_usd: 3_000_000,
    withdrawable_balance_usd: "3.000000",
    ...overrides,
  };
}

function mockEarnings(body: unknown) {
  const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => body });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

async function renderLoaded(body: unknown) {
  const fetchMock = mockEarnings(body);
  render(<EarningsContent />);
  await screen.findByText("Provider Earnings");
  expect(fetchMock).toHaveBeenCalledWith("/api/me/earnings?limit=100", expect.anything());
}

describe("EarningsContent", () => {
  beforeEach(() => {
    localStorage.clear();
  });
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("J5: hides Avg per Job when the response has no work_usd", async () => {
    await renderLoaded(response());
    expect(screen.getByText("Total Earned")).toBeInTheDocument();
    expect(screen.queryByText("Avg per Job")).toBeNull();
  });

  it("J6: shows Avg per Job as work_usd / count to 6 decimals", async () => {
    // total includes base rewards; the average must use work_usd only.
    await renderLoaded(response({ work_usd: "2.000000", count: 3 }));
    expect(screen.getByText("Avg per Job")).toBeInTheDocument();
    expect(screen.getByText("$0.666667")).toBeInTheDocument();
  });

  it("J7: activity header is Source; base_reward renders as Base reward; models show short name", async () => {
    await renderLoaded(
      response({
        earnings: [
          earning(1, "mlx-community/Qwen3-8B", 1_000_000),
          earning(2, "base_reward", 500_000),
        ],
        recent_count: 2,
      }),
    );
    expect(screen.getByRole("columnheader", { name: "Source" })).toBeInTheDocument();
    expect(screen.queryByRole("columnheader", { name: "Model" })).toBeNull();
    expect(screen.getByText("Base reward")).toBeInTheDocument();
    expect(screen.queryByText("base_reward")).toBeNull();
    expect(screen.getByText("Qwen3-8B")).toBeInTheDocument();
  });

  it("J8: caption reads 'Showing the latest N payouts.' once recent_count reaches history_limit", async () => {
    await renderLoaded(response({ recent_count: 100, history_limit: 100, count: 40 }));
    await waitFor(() => expect(screen.getByText("Showing the latest 100 payouts.")).toBeInTheDocument());
    expect(screen.queryByText(/ of /)).toBeNull();
  });

  it("J8: no caption below the history limit", async () => {
    await renderLoaded(response({ recent_count: 1, history_limit: 100, count: 400 }));
    expect(screen.queryByText(/Showing the latest/)).toBeNull();
  });
});
