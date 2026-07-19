import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, act, render, screen, fireEvent } from "@testing-library/react";
import { useStripePayouts } from "@/components/payouts/useStripePayouts";
import { StripePayoutsCard } from "@/components/payouts/StripePayoutsCard";
import { formatAutoWithdrawNextAt } from "@/components/payouts/AutoWithdrawControl";
import { WithdrawalsList } from "@/components/payouts/WithdrawalsList";
import type { StripeStatus } from "@/lib/api";

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    fetchStripeStatus: vi.fn(),
    startStripeOnboarding: vi.fn(),
    withdrawStripe: vi.fn(),
    fetchStripeWithdrawals: vi.fn(),
    setStripeAutoWithdraw: vi.fn(),
  };
});

import {
  ApiError,
  fetchStripeStatus,
  withdrawStripe,
  fetchStripeWithdrawals,
  setStripeAutoWithdraw,
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

  it("setAutoWithdraw() persists opt-in and updates status", async () => {
    (fetchStripeStatus as ReturnType<typeof vi.fn>).mockResolvedValue(readyStatus);
    (fetchStripeWithdrawals as ReturnType<typeof vi.fn>).mockResolvedValue([]);
    (setStripeAutoWithdraw as ReturnType<typeof vi.fn>).mockResolvedValue({
      auto_withdraw_enabled: true,
      auto_withdraw_next_at: "2026-07-20T09:00:00Z",
      auto_withdraw_cadence: "weekly",
      auto_withdraw_method: "standard",
    });
    const addToast = vi.fn();
    const { result } = renderHook(() => useStripePayouts({ addToast, enabled: false }));
    await act(async () => {
      await result.current.reload();
      await result.current.setAutoWithdraw(true);
    });

    expect(setStripeAutoWithdraw).toHaveBeenCalledWith(true);
    expect(result.current.status?.auto_withdraw_enabled).toBe(true);
    expect(addToast).toHaveBeenCalledWith(
      "Automatic weekly withdrawals enabled",
      "success",
    );

    (setStripeAutoWithdraw as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      auto_withdraw_enabled: false,
      auto_withdraw_authorized_at: null,
      auto_withdraw_next_at: null,
      auto_withdraw_cadence: "weekly",
      auto_withdraw_method: "standard",
    });
    await act(async () => {
      await result.current.setAutoWithdraw(false);
    });
    expect(setStripeAutoWithdraw).toHaveBeenLastCalledWith(false);
    expect(result.current.status?.auto_withdraw_enabled).toBe(false);
  });

  it("does not let an older reload overwrite a completed toggle", async () => {
    let resolveStaleStatus!: (status: StripeStatus) => void;
    const staleStatus = new Promise<StripeStatus>((resolve) => {
      resolveStaleStatus = resolve;
    });
    (fetchStripeStatus as ReturnType<typeof vi.fn>).mockReturnValueOnce(staleStatus);
    (fetchStripeWithdrawals as ReturnType<typeof vi.fn>).mockResolvedValue([]);
    (setStripeAutoWithdraw as ReturnType<typeof vi.fn>).mockResolvedValue({
      auto_withdraw_enabled: true,
      auto_withdraw_next_at: "2026-07-20T09:00:00Z",
      auto_withdraw_cadence: "weekly",
      auto_withdraw_method: "standard",
    });
    const { result } = renderHook(() =>
      useStripePayouts({ addToast: vi.fn(), enabled: false }),
    );

    let pendingReload!: Promise<void>;
    act(() => {
      pendingReload = result.current.reload();
    });
    await act(async () => {
      // Seed the already-rendered status a real user would have before clicking.
      resolveStaleStatus(readyStatus);
      await pendingReload;
    });

    // Start another reload that will return stale "disabled" data.
    let resolveSecondStatus!: (status: StripeStatus) => void;
    (fetchStripeStatus as ReturnType<typeof vi.fn>).mockReturnValueOnce(
      new Promise<StripeStatus>((resolve) => {
        resolveSecondStatus = resolve;
      }),
    );
    (fetchStripeWithdrawals as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      {
        id: "wd-fresh-history",
        status: "transferred",
        net_micro_usd: 5_000_000,
        method: "standard",
      },
    ]);
    act(() => {
      pendingReload = result.current.reload();
    });
    await act(async () => {
      await result.current.setAutoWithdraw(true);
    });
    await act(async () => {
      resolveSecondStatus({ ...readyStatus, auto_withdraw_enabled: false });
      await pendingReload;
    });

    expect(result.current.status?.auto_withdraw_enabled).toBe(true);
    expect(result.current.withdrawals[0]?.id).toBe("wd-fresh-history");
  });

  it("exposes loading while an automatic-withdraw update is in flight", async () => {
    let resolveUpdate!: (value: {
      auto_withdraw_enabled: boolean;
      auto_withdraw_cadence: "weekly";
      auto_withdraw_method: "standard";
    }) => void;
    (setStripeAutoWithdraw as ReturnType<typeof vi.fn>).mockReturnValueOnce(
      new Promise((resolve) => {
        resolveUpdate = resolve;
      }),
    );
    const { result } = renderHook(() =>
      useStripePayouts({ addToast: vi.fn(), enabled: false }),
    );

    let pending!: Promise<void>;
    await act(async () => {
      pending = result.current.setAutoWithdraw(true);
      await Promise.resolve();
    });
    expect(result.current.autoWithdrawLoading).toBe(true);

    await act(async () => {
      resolveUpdate({
        auto_withdraw_enabled: true,
        auto_withdraw_cadence: "weekly",
        auto_withdraw_method: "standard",
      });
      await pending;
    });
    expect(result.current.autoWithdrawLoading).toBe(false);
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
        onAutoWithdrawChange={noop}
        autoWithdrawLoading={false}
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
        onAutoWithdrawChange={noop}
        autoWithdrawLoading={false}
        title="Withdraw to Bank"
        icon={null}
        noun="credits"
        className="card"
      />,
    );
    expect(screen.getByText("Ready")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /withdraw/i })).not.toBeDisabled();
  });

  it("shows the weekly schedule and lets the user revoke authorization", () => {
    const onAutoWithdrawChange = vi.fn();
    render(
      <StripePayoutsCard
        status={{
          ...readyStatus,
          auto_withdraw_enabled: true,
          auto_withdraw_next_at: "2026-07-20T09:00:00Z",
        }}
        withdrawals={[]}
        balanceMicroUsd={5_000_000}
        onboardLoading={false}
        selectedCountry="US"
        onCountryChange={noop}
        onOnboard={noop}
        onOpenWithdraw={noop}
        onAutoWithdrawChange={onAutoWithdrawChange}
        autoWithdrawLoading={false}
        title="Withdraw to Bank"
        icon={null}
        noun="earnings"
        className="card"
      />,
    );

    const toggle = screen.getByRole("switch", {
      name: "Automatic weekly withdrawals",
    });
    expect(toggle).toHaveAttribute("aria-checked", "true");
    expect(screen.getByText(/Next check: Mon, Jul 20/)).toBeInTheDocument();
    fireEvent.click(toggle);
    expect(onAutoWithdrawChange).toHaveBeenCalledWith(false);
  });

  it("keeps opt-out available while the Stripe account is restricted", () => {
    const onAutoWithdrawChange = vi.fn();
    render(
      <StripePayoutsCard
        status={{
          ...readyStatus,
          status: "restricted",
          auto_withdraw_enabled: true,
          auto_withdraw_next_at: "2026-07-20T09:00:00Z",
        }}
        withdrawals={[]}
        balanceMicroUsd={5_000_000}
        onboardLoading={false}
        selectedCountry="US"
        onCountryChange={noop}
        onOnboard={noop}
        onOpenWithdraw={noop}
        onAutoWithdrawChange={onAutoWithdrawChange}
        autoWithdrawLoading={false}
        title="Withdraw to Bank"
        icon={null}
        noun="earnings"
        className="card"
      />,
    );

    expect(screen.getByText(/Paused - automatic withdrawals/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("switch", {
      name: "Automatic weekly withdrawals",
    }));
    expect(onAutoWithdrawChange).toHaveBeenCalledWith(false);
  });

  it("keeps opt-out available during a Stripe configuration outage", () => {
    render(
      <StripePayoutsCard
        status={{
          configured: false,
          has_account: true,
          status: "ready",
          auto_withdraw_enabled: true,
        }}
        withdrawals={[]}
        balanceMicroUsd={0}
        onboardLoading={false}
        selectedCountry=""
        onCountryChange={noop}
        onOnboard={noop}
        onOpenWithdraw={noop}
        onAutoWithdrawChange={noop}
        autoWithdrawLoading={false}
        title="Withdraw to Bank"
        icon={null}
        noun="earnings"
        className="card"
      />,
    );

    expect(screen.getByText(/temporarily unavailable/)).toBeInTheDocument();
    expect(screen.getByRole("switch", {
      name: "Automatic weekly withdrawals",
    })).not.toBeDisabled();
  });
});

describe("automatic withdrawal presentation", () => {
  it("formats the schedule explicitly in UTC", () => {
    expect(formatAutoWithdrawNextAt("2026-07-20T09:00:00Z"))
      .toBe("Mon, Jul 20, 9:00 AM UTC");
  });

  it("labels automatic withdrawals in history", () => {
    render(
      <WithdrawalsList
        withdrawals={[{
          id: "wd-auto",
          account_id: "acct",
          stripe_account_id: "acct_stripe",
          amount_micro_usd: 5_000_000,
          fee_micro_usd: 0,
          net_micro_usd: 5_000_000,
          method: "standard",
          source: "automatic",
          status: "transferred",
          created_at: "2026-07-20T09:00:00Z",
          updated_at: "2026-07-20T09:00:01Z",
        }]}
      />,
    );
    expect(screen.getByText("weekly auto")).toBeInTheDocument();
  });
});
