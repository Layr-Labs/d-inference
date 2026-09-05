import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { GlobalWithdrawModal } from "./GlobalWithdrawModal";
import { withdrawalStatusPresentation, withdrawSuccessMessage } from "./payout-copy";
import type { BankWithdrawalQuote, StripeStatus } from "@/lib/api";

const status: StripeStatus = { configured: true, has_account: true, status: "ready", payout_rail: "global", payout_currency: "inr", destination_last4: "1234" };
const quote: BankWithdrawalQuote = { id: "quote-1", amount_usd: "10.00", fee_usd: "0.00", destination_amount: 80000, currency: "inr", currency_exponent: 2, expires_at: "2099-01-01T00:00:00Z", destination_last4: "1234", eta: "Typically 1–7 business days" };
function props() { return { status, balanceMicroUsd: 20_000_000, amount: "10", loading: false, onAmountChange: vi.fn(), onConfirm: vi.fn(), onCancel: vi.fn() }; }

describe("international bank withdrawal", () => {
  it("reviews the local deposit before confirming without exposing product choices", () => {
    const p = props(); const { rerender } = render(<GlobalWithdrawModal {...p} />);
    fireEvent.click(screen.getByRole("button", { name: "Review withdrawal" }));
    expect(p.onConfirm).toHaveBeenCalledOnce();
    expect(screen.queryByText("Instant")).not.toBeInTheDocument();
    rerender(<GlobalWithdrawModal {...p} quote={quote} />);
    expect(screen.getByText("Estimated bank deposit")).toBeInTheDocument();
    expect(screen.getByText(/800\.00/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Confirm withdrawal" })).toBeEnabled();
  });
  it("requires an expired quote to be refreshed", () => {
    render(<GlobalWithdrawModal {...props()} quote={{ ...quote, expires_at: "2020-01-01T00:00:00Z" }} />);
    expect(screen.getByRole("button", { name: "Refresh estimate" })).toBeEnabled();
    expect(screen.queryByRole("button", { name: "Confirm withdrawal" })).not.toBeInTheDocument();
  });
  it("keeps an uncertain submitted withdrawal distinct from a new quote", () => {
    render(<GlobalWithdrawModal {...props()} balanceMicroUsd={0} confirmationPending quote={{ ...quote, expires_at: "2020-01-01T00:00:00Z" }} />);
    expect(screen.getByLabelText("Amount (USD)")).toBeDisabled();
    expect(screen.getByRole("button", { name: "Check withdrawal" })).toBeEnabled();
    expect(screen.queryByRole("button", { name: "Refresh estimate" })).not.toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Close" })).toBeEnabled();
  });
  it("does not describe a posted transfer as bank receipt", () => {
    expect(withdrawalStatusPresentation("posted").label).toBe("Sent to bank");
    expect(withdrawSuccessMessage({ status: "posted", method: "standard", payout_rail: "global" })).toContain("bank may take");
    expect(withdrawalStatusPresentation("returned", true).label).toBe("Returned to balance");
    expect(withdrawalStatusPresentation("processing", false, "under_review").label).toBe("Under review");
  });
});
