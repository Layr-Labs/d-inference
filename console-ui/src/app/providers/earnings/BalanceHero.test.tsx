// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { BalanceHero, heroCta } from "./BalanceHero";
import { makeScenario, makeStripeStatus } from "./testFixtures";

describe("heroCta", () => {
  it("disables quietly while payout status is still loading", () => {
    expect(heroCta(null, 100, 1)).toMatchObject({
      action: "withdraw",
      disabled: true,
      hint: null,
    });
  });

  it("returns no CTA when payouts are disabled on this coordinator", () => {
    expect(heroCta(makeStripeStatus({ configured: false }), 100, 1)).toBeNull();
  });

  it("offers a retry when the status fetch failed", () => {
    const cta = heroCta(null, 100, 1, true)!;
    expect(cta).toMatchObject({
      label: "Reload payout status",
      action: "retry",
      disabled: false,
    });
    expect(cta.hint).toMatch(/couldn't check your payout status/i);
  });

  it("points an unlinked user at setup instead of a dead button", () => {
    const cta = heroCta(makeStripeStatus({ has_account: false, status: "" }), 100, 1)!;
    expect(cta).toMatchObject({
      label: "Link bank to withdraw",
      action: "setup",
      disabled: false,
    });
    expect(cta.hint).toMatch(/No payout method linked/);
  });

  it("sends a pending account to finish setup", () => {
    const cta = heroCta(makeStripeStatus({ status: "pending" }), 100, 1);
    expect(cta).toMatchObject({ label: "Finish payout setup", action: "setup" });
  });

  it("sends restricted and rejected accounts to fix setup", () => {
    for (const status of ["restricted", "rejected"] as const) {
      expect(heroCta(makeStripeStatus({ status }), 100, 1)).toMatchObject({
        label: "Fix payout setup",
        action: "setup",
        disabled: false,
      });
    }
  });

  it("disables withdraw below the minimum, with an explanatory hint", () => {
    const cta = heroCta(makeStripeStatus(), 0.48, 1)!;
    expect(cta).toMatchObject({ action: "withdraw", disabled: true });
    expect(cta.hint).toBe(
      "Minimum withdrawal is $1.00 — your withdrawable balance is $0.48.",
    );
  });

  it("enables withdraw when linked, ready, and above the minimum", () => {
    expect(heroCta(makeStripeStatus(), 326.4, 1)).toMatchObject({
      label: "Withdraw earnings",
      action: "withdraw",
      disabled: false,
      hint: null,
    });
  });
});

function renderHero({
  scenario = "TYPICAL" as Parameters<typeof makeScenario>[0],
  status = makeStripeStatus(),
  onWithdraw = vi.fn(),
  onSetup = vi.fn(),
} = {}) {
  const s = makeScenario(scenario);
  render(
    <BalanceHero
      totalBalanceMicro={s.available_balance_micro_usd}
      withdrawableMicro={s.withdrawable_balance_micro_usd}
      status={status}
      minWithdrawUsd={1}
      onWithdraw={onWithdraw}
      onSetup={onSetup}
    />,
  );
  return { onWithdraw, onSetup };
}

describe("BalanceHero", () => {
  it("shows balance, withdrawable, and the credits split (CREDITS_ONLY)", () => {
    renderHero({ scenario: "CREDITS_ONLY" });
    // $15.78 appears as both the headline balance and the credits split.
    expect(screen.getAllByText("$15.78")).toHaveLength(2);
    expect(screen.getByText("$0.00")).toBeInTheDocument();
    expect(screen.getByText("credits · non-withdrawable")).toBeInTheDocument();
  });

  it("hides the credits split when there are no credits", () => {
    render(
      <BalanceHero
        totalBalanceMicro={5_000_000}
        withdrawableMicro={5_000_000}
        status={makeStripeStatus()}
        minWithdrawUsd={1}
        onWithdraw={vi.fn()}
        onSetup={vi.fn()}
      />,
    );
    expect(screen.queryByText("credits · non-withdrawable")).toBeNull();
  });

  it("fires onWithdraw when ready with enough balance", () => {
    const { onWithdraw } = renderHero();
    fireEvent.click(screen.getByRole("button", { name: /withdraw earnings/i }));
    expect(onWithdraw).toHaveBeenCalledOnce();
  });

  it("fires onSetup from the link-bank CTA when no account is linked", () => {
    const { onWithdraw, onSetup } = renderHero({
      status: makeStripeStatus({ has_account: false, status: "" }),
    });
    fireEvent.click(screen.getByRole("button", { name: /link bank to withdraw/i }));
    expect(onSetup).toHaveBeenCalledOnce();
    expect(onWithdraw).not.toHaveBeenCalled();
  });

  it("disables withdraw below the minimum (BELOW_MIN_WITHDRAW)", () => {
    const { onWithdraw } = renderHero({ scenario: "BELOW_MIN_WITHDRAW" });
    const btn = screen.getByRole("button", { name: /withdraw earnings/i });
    expect(btn).toBeDisabled();
    expect(screen.getByText(/Minimum withdrawal is \$1\.00/)).toBeInTheDocument();
    fireEvent.click(btn);
    expect(onWithdraw).not.toHaveBeenCalled();
  });

  it("shows the linked destination with a change link when ready", () => {
    const onOpenDashboard = vi.fn();
    const s = makeScenario("TYPICAL");
    render(
      <BalanceHero
        totalBalanceMicro={s.available_balance_micro_usd}
        withdrawableMicro={s.withdrawable_balance_micro_usd}
        status={makeStripeStatus()}
        minWithdrawUsd={1}
        onWithdraw={vi.fn()}
        onSetup={vi.fn()}
        onOpenDashboard={onOpenDashboard}
      />,
    );
    expect(screen.getByText("Bank ••4821")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /change/i }));
    expect(onOpenDashboard).toHaveBeenCalledOnce();
  });

  it("fires onRetryStatus from the reload CTA after a failed status fetch", () => {
    const onRetryStatus = vi.fn();
    const s = makeScenario("TYPICAL");
    render(
      <BalanceHero
        totalBalanceMicro={s.available_balance_micro_usd}
        withdrawableMicro={s.withdrawable_balance_micro_usd}
        status={null}
        statusFailed
        minWithdrawUsd={1}
        onWithdraw={vi.fn()}
        onSetup={vi.fn()}
        onRetryStatus={onRetryStatus}
      />,
    );
    fireEvent.click(
      screen.getByRole("button", { name: /reload payout status/i }),
    );
    expect(onRetryStatus).toHaveBeenCalledOnce();
  });

  it("hides the whole CTA column when payouts are disabled", () => {
    renderHero({ status: makeStripeStatus({ configured: false }) });
    expect(screen.queryByRole("button", { name: /withdraw/i })).toBeNull();
  });

  it("hides the destination line while unlinked", () => {
    renderHero({ status: makeStripeStatus({ has_account: false, status: "" }) });
    expect(screen.queryByText(/••4821/)).toBeNull();
  });

  it("formats whale-sized balances with separators (WHALE)", () => {
    renderHero({ scenario: "WHALE" });
    expect(screen.getByText("$812,412.55")).toBeInTheDocument();
  });
});
