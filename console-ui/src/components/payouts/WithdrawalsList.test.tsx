import { describe, expect, it } from "vitest";
import { fireEvent, render, screen, within } from "@testing-library/react";
import type { StripeWithdrawal } from "@/lib/api";
import { WithdrawalsList } from "./WithdrawalsList";

function withdrawal(overrides: Partial<StripeWithdrawal> = {}): StripeWithdrawal {
  return {
    id: "withdrawal-123", account_id: "account-1", stripe_account_id: "stripe-account-1",
    amount_micro_usd: 10_000_000, fee_micro_usd: 0, net_micro_usd: 10_000_000,
    method: "standard", status: "pending", created_at: "2026-09-28T12:00:00Z",
    updated_at: "2026-09-28T12:05:00Z", ...overrides,
  };
}

describe("WithdrawalsList", () => {
  it("makes reconciliation guidance readable without hovering and exposes a support reference", () => {
    render(<WithdrawalsList withdrawals={[withdrawal({ failure_reason: "manual_reconciliation_required" })]} />);
    expect(screen.getByText("Needs review")).toBeVisible();
    expect(screen.getByText(/funds remain reserved; do not submit another payment/)).toBeVisible();
    const summary = screen.getByText("Withdrawal details");
    fireEvent.click(summary);
    expect(summary.closest("details")).toHaveAttribute("open");
    expect(screen.getByText("withdrawal-123")).toBeVisible();
    expect(screen.getByText("2026-09-28 12:00:00 UTC")).toBeVisible();
    expect(screen.queryByText("stripe-account-1")).not.toBeInTheDocument();
    expect(screen.queryByText("account-1")).not.toBeInTheDocument();
  });

  it.each([
    ["returned", true, "Returned to balance", /available earnings were restored/],
    ["returned", false, "Return pending", /being reconciled/],
    ["failed", true, "Failed - refunded", /refunded to your balance/],
    ["failed", false, "Failed - contact support", /Contact support to resolve it/],
  ] as const)("explains %s with refunded=%s using confirmed balance state", (status, refunded, label, detail) => {
    render(<WithdrawalsList withdrawals={[withdrawal({ status, refunded })]} />);
    expect(screen.getByText(label)).toBeVisible();
    expect(screen.getByText(detail)).toBeVisible();
  });

  it("keeps an unresolved withdrawal beyond the first five reachable", () => {
    const recent = Array.from({ length: 5 }, (_, i) => withdrawal({ id: `recent-${i}`, status: "paid" }));
    render(<WithdrawalsList withdrawals={[...recent, withdrawal({ status: "failed" })]} />);
    const summary = screen.getByText("Show 1 more withdrawal");
    const more = summary.closest("details")!;
    expect(more).not.toHaveAttribute("open");
    fireEvent.click(summary);
    expect(more).toHaveAttribute("open");
    expect(within(more).getByText("Failed - contact support")).toBeVisible();
    fireEvent.click(within(more).getByText("Withdrawal details"));
    expect(within(more).getByText("withdrawal-123")).toBeVisible();
  });

  it("preserves the quoted local currency and handles an unavailable date", () => {
    render(<WithdrawalsList withdrawals={[withdrawal({
      payout_rail: "global", payout_currency: "jpy", destination_amount: 1500,
      currency_exponent: 0, created_at: "",
    })]} />);
    expect(screen.getByText(/1,500/)).toBeVisible();
    expect(screen.queryByText("$10.00")).not.toBeInTheDocument();
    fireEvent.click(screen.getByText("Withdrawal details"));
    expect(screen.getByText("Date unavailable")).toBeVisible();
    expect(screen.queryByText(/Invalid Date/)).not.toBeInTheDocument();
  });

  it("does not imply more history exists for a short or empty response", () => {
    const { rerender } = render(<WithdrawalsList withdrawals={[withdrawal()]} />);
    expect(screen.queryByText(/more withdrawal/)).not.toBeInTheDocument();
    rerender(<WithdrawalsList withdrawals={[]} />);
    expect(screen.queryByText("Recent withdrawals")).not.toBeInTheDocument();
  });
});
