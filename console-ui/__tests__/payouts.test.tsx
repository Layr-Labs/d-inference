import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, act, render, screen, waitFor } from "@testing-library/react";
import { useStripePayouts } from "@/components/payouts/useStripePayouts";
import { StripePayoutsCard } from "@/components/payouts/StripePayoutsCard";
import type { StripeStatus } from "@/lib/api";

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    fetchStripeStatus: vi.fn(),
    startStripeOnboarding: vi.fn(),
    withdrawStripe: vi.fn(),
    fetchStripeWithdrawals: vi.fn(),
  };
});

import {
  fetchStripeStatus,
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
    (withdrawStripe as ReturnType<typeof vi.fn>).mockResolvedValue({ eta: "~30 minutes" });

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
    expect(addToast).toHaveBeenCalledWith(expect.stringContaining("Withdrawal submitted"), "success");
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
});
