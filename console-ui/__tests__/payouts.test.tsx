import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { renderHook, act, render, screen, fireEvent } from "@testing-library/react";
import { useStripePayouts } from "@/components/payouts/useStripePayouts";
import { StripePayoutsCard } from "@/components/payouts/StripePayoutsCard";
import type { StripeStatus } from "@/lib/api";

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    fetchStripeStatus: vi.fn(),
    startStripeOnboarding: vi.fn(),
    createStripeDashboardLink: vi.fn(),
    withdrawStripe: vi.fn(),
    fetchStripeWithdrawals: vi.fn(),
  };
});

import {
  ApiError,
  fetchStripeStatus,
  createStripeDashboardLink,
  withdrawStripe,
  fetchStripeWithdrawals,
} from "@/lib/api";

const readyStatus: StripeStatus = {
  configured: true,
  has_account: true,
  status: "ready",
  destination_type: "bank",
  destination_last4: "4242",
  instant_eligible: true,
  min_withdraw_micro_usd: 1_000_000,
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("useStripePayouts", () => {
  it("reload() populates status and withdrawals", async () => {
    (fetchStripeStatus as ReturnType<typeof vi.fn>).mockResolvedValue(readyStatus);
    (fetchStripeWithdrawals as ReturnType<typeof vi.fn>).mockResolvedValue([
      { id: "wd-1", status: "paid", net_micro_usd: 5_000_000, method: "standard" },
    ]);

    const addToast = vi.fn();
    const { result } = renderHook(() => useStripePayouts({ addToast, enabled: false }));

    await act(async () => {
      await result.current.reload();
    });

    expect(result.current.status?.status).toBe("ready");
    expect(result.current.withdrawals).toHaveLength(1);
  });

  it("openWithdraw seeds amount and prefers instant when eligible", async () => {
    (fetchStripeStatus as ReturnType<typeof vi.fn>).mockResolvedValue(readyStatus);
    (fetchStripeWithdrawals as ReturnType<typeof vi.fn>).mockResolvedValue([]);
    const addToast = vi.fn();
    const { result } = renderHook(() => useStripePayouts({ addToast, enabled: false }));
    await act(async () => {
      await result.current.reload();
    });

    act(() => result.current.openWithdraw("25.00"));
    expect(result.current.withdrawOpen).toBe(true);
    expect(result.current.withdrawAmount).toBe("25.00");
    expect(result.current.withdrawMethod).toBe("instant");
  });

  it("withdraw() submits, reloads, toasts, and fires analytics", async () => {
    (fetchStripeStatus as ReturnType<typeof vi.fn>).mockResolvedValue(readyStatus);
    (fetchStripeWithdrawals as ReturnType<typeof vi.fn>).mockResolvedValue([]);
    (withdrawStripe as ReturnType<typeof vi.fn>).mockResolvedValue({
      status: "transferred",
      method: "standard",
      eta: "1-3 business days",
    });

    const addToast = vi.fn();
    const onAfterWithdraw = vi.fn().mockResolvedValue(undefined);
    const onWithdrawStart = vi.fn();
    const onWithdrawSuccess = vi.fn();
    const { result } = renderHook(() =>
      useStripePayouts({ addToast, enabled: false, onAfterWithdraw, onWithdrawStart, onWithdrawSuccess }),
    );
    act(() => result.current.setWithdrawAmount("10"));

    await act(async () => {
      await result.current.withdraw();
    });

    expect(withdrawStripe).toHaveBeenCalledWith("10", "standard");
    expect(onWithdrawStart).toHaveBeenCalledWith("standard");
    expect(onWithdrawSuccess).toHaveBeenCalledWith("standard");
    expect(onAfterWithdraw).toHaveBeenCalled();
    expect(addToast).toHaveBeenCalledWith(expect.stringContaining("On its way"), "success");
    expect(result.current.withdrawOpen).toBe(false);
  });

  it("withdraw() surfaces errors and fires the error analytics", async () => {
    (withdrawStripe as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("insufficient balance"));
    const addToast = vi.fn();
    const onWithdrawError = vi.fn();
    const { result } = renderHook(() =>
      useStripePayouts({ addToast, enabled: false, onWithdrawError }),
    );

    await act(async () => {
      await result.current.withdraw();
    });

    expect(onWithdrawError).toHaveBeenCalled();
    expect(addToast).toHaveBeenCalledWith("insufficient balance");
  });

  it("withdraw() on stripe_account_gone shows friendly copy, closes the modal, and refreshes status", async () => {
    // The backend auto-unlinked the account, so the status refresh returns
    // the not-configured card state (has_account: false).
    (withdrawStripe as ReturnType<typeof vi.fn>).mockRejectedValue(
      new ApiError("your Stripe payout account no longer exists", "stripe_account_gone", 409),
    );
    (fetchStripeStatus as ReturnType<typeof vi.fn>).mockResolvedValue({
      ...readyStatus,
      has_account: false,
      status: "",
    });
    (fetchStripeWithdrawals as ReturnType<typeof vi.fn>).mockResolvedValue([]);

    const addToast = vi.fn();
    const { result } = renderHook(() => useStripePayouts({ addToast, enabled: false }));
    act(() => result.current.setWithdrawOpen(true));

    await act(async () => {
      await result.current.withdraw();
    });

    expect(addToast).toHaveBeenCalledWith(expect.stringContaining("Your Stripe account was closed"));
    expect(result.current.withdrawOpen).toBe(false);
    expect(fetchStripeStatus).toHaveBeenCalled(); // status refreshed -> card returns to setup state
    expect(result.current.status?.has_account).toBe(false);
  });
});

// The Express Dashboard login link is single-use: if we mint one and then
// fail to navigate to it, the user is stranded and has to start over. These
// pin the navigation paths rather than the (trivial) copy mapping.
describe("useStripePayouts.openDashboard", () => {
  const LINK = "https://connect.stripe.com/express/acct_1/tok";

  // These spy on window.open / window.location, which clearAllMocks leaves
  // installed — restore so later suites get the real objects back.
  afterEach(() => vi.restoreAllMocks());

  function stubWindowOpen(tab: Partial<Window> | null) {
    const open = vi.fn().mockReturnValue(tab);
    vi.spyOn(window, "open").mockImplementation(open as unknown as typeof window.open);
    return open;
  }

  function fakeTab(closed = false) {
    return { closed, opener: {} as unknown, location: { replace: vi.fn() }, close: vi.fn() };
  }

  it("navigates the pre-opened tab and disowns it before it points at Stripe", async () => {
    (createStripeDashboardLink as ReturnType<typeof vi.fn>).mockResolvedValue({ url: LINK });
    const tab = fakeTab();
    const open = stubWindowOpen(tab as unknown as Window);

    const { result } = renderHook(() => useStripePayouts({ addToast: vi.fn(), enabled: false }));
    await act(async () => {
      await result.current.openDashboard();
    });

    // Opened synchronously with a blank URL so the popup blocker sees a
    // user gesture, then navigated once the link arrives.
    expect(open).toHaveBeenCalledWith("", "_blank");
    expect(tab.opener).toBeNull();
    expect(tab.location.replace).toHaveBeenCalledWith(LINK);
    expect(result.current.dashboardLoading).toBe(false);
  });

  it("falls back to the current tab when the popup is blocked", async () => {
    (createStripeDashboardLink as ReturnType<typeof vi.fn>).mockResolvedValue({ url: LINK });
    stubWindowOpen(null);
    const replace = vi.fn();
    vi.spyOn(window, "location", "get").mockReturnValue({ replace } as unknown as Location);

    const { result } = renderHook(() => useStripePayouts({ addToast: vi.fn(), enabled: false }));
    await act(async () => {
      await result.current.openDashboard();
    });

    // replace(), not href: the link is a credential and must not enter history.
    expect(replace).toHaveBeenCalledWith(LINK);
  });

  it("falls back to the current tab when the user closed the pre-opened one", async () => {
    (createStripeDashboardLink as ReturnType<typeof vi.fn>).mockResolvedValue({ url: LINK });
    const tab = fakeTab(true);
    stubWindowOpen(tab as unknown as Window);
    const replace = vi.fn();
    vi.spyOn(window, "location", "get").mockReturnValue({ replace } as unknown as Location);

    const { result } = renderHook(() => useStripePayouts({ addToast: vi.fn(), enabled: false }));
    await act(async () => {
      await result.current.openDashboard();
    });

    expect(tab.location.replace).not.toHaveBeenCalled();
    expect(replace).toHaveBeenCalledWith(LINK);
  });

  it("closes the orphan tab and toasts friendly copy when minting fails", async () => {
    (createStripeDashboardLink as ReturnType<typeof vi.fn>).mockRejectedValue(
      new ApiError("your Stripe account no longer exists", "stripe_account_gone", 409),
    );
    (fetchStripeStatus as ReturnType<typeof vi.fn>).mockResolvedValue({
      ...readyStatus,
      has_account: false,
      status: "",
    });
    (fetchStripeWithdrawals as ReturnType<typeof vi.fn>).mockResolvedValue([]);
    const tab = fakeTab();
    stubWindowOpen(tab as unknown as Window);

    const addToast = vi.fn();
    const { result } = renderHook(() => useStripePayouts({ addToast, enabled: false }));
    await act(async () => {
      await result.current.openDashboard();
    });

    expect(tab.close).toHaveBeenCalled();
    expect(tab.location.replace).not.toHaveBeenCalled();
    expect(addToast).toHaveBeenCalledWith(expect.stringContaining("Your Stripe account was closed"));
    expect(result.current.status?.has_account).toBe(false);
    expect(result.current.dashboardLoading).toBe(false);
  });

  it("never navigates to an empty url when the response body is malformed", async () => {
    (createStripeDashboardLink as ReturnType<typeof vi.fn>).mockResolvedValue({});
    const tab = fakeTab();
    stubWindowOpen(tab as unknown as Window);

    const addToast = vi.fn();
    const { result } = renderHook(() => useStripePayouts({ addToast, enabled: false }));
    await act(async () => {
      await result.current.openDashboard();
    });

    expect(tab.location.replace).not.toHaveBeenCalled();
    expect(tab.close).toHaveBeenCalled();
    expect(addToast).toHaveBeenCalledWith(expect.stringContaining("didn't return a dashboard link"));
  });
});

describe("StripePayoutsCard", () => {
  const noop = () => {};

  it("hides itself when Stripe is not configured", () => {
    const { container } = render(
      <StripePayoutsCard
        status={{ configured: false, has_account: false, status: "" }}
        withdrawals={[]}
        balanceMicroUsd={0}
        onboardLoading={false}
        selectedCountry=""
        onCountryChange={noop}
        onOnboard={noop}
        onOpenWithdraw={noop}
        title="Withdraw to Bank"
        icon={null}
        noun="credits"
        className="card"
      />,
    );
    expect(container.firstChild).toBeNull();
  });

  it("shows a Ready badge and enables withdraw above the minimum", () => {
    render(
      <StripePayoutsCard
        status={readyStatus}
        withdrawals={[]}
        balanceMicroUsd={5_000_000}
        onboardLoading={false}
        selectedCountry="US"
        onCountryChange={noop}
        onOnboard={noop}
        onOpenWithdraw={noop}
        title="Withdraw to Bank"
        icon={null}
        noun="credits"
        className="card"
      />,
    );
    expect(screen.getByText("Ready")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /withdraw/i })).not.toBeDisabled();
  });

  it("offers 'Change in Stripe' next to the destination once ready", () => {
    const onOpenDashboard = vi.fn();
    render(
      <StripePayoutsCard
        status={readyStatus}
        withdrawals={[]}
        balanceMicroUsd={5_000_000}
        onboardLoading={false}
        selectedCountry="US"
        onCountryChange={noop}
        onOnboard={noop}
        onOpenWithdraw={noop}
        onOpenDashboard={onOpenDashboard}
        title="Withdraw to Bank"
        icon={null}
        noun="credits"
        className="card"
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /change in stripe/i }));
    expect(onOpenDashboard).toHaveBeenCalledTimes(1);
  });

  it("omits the change action when the page doesn't wire it up", () => {
    render(
      <StripePayoutsCard
        status={readyStatus}
        withdrawals={[]}
        balanceMicroUsd={5_000_000}
        onboardLoading={false}
        selectedCountry="US"
        onCountryChange={noop}
        onOnboard={noop}
        onOpenWithdraw={noop}
        title="Withdraw to Bank"
        icon={null}
        noun="credits"
        className="card"
      />,
    );
    expect(screen.queryByRole("button", { name: /change in stripe/i })).toBeNull();
  });
});
