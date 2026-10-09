import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { StripePayoutsCard } from "./StripePayoutsCard";

describe("bank payout migration", () => {
  it("asks the user to complete bank setup without offering withdrawal or instant payouts", () => {
    const onboard = vi.fn();
    render(<StripePayoutsCard status={{ configured: true, has_account: false, status: "pending", payout_rail: "global", migration_required: true, stripe_account_country: "US", instant_eligible: false, countries: [{ code: "US", name: "United States", rail: "global" }] }} withdrawals={[]} balanceMicroUsd={10_000_000} onboardLoading={false} selectedCountry="US" onCountryChange={vi.fn()} onOnboard={onboard} onOpenWithdraw={vi.fn()} title="Bank withdrawals" noun="earnings" icon={null} className="" />);
    expect(screen.getByRole("status")).toHaveTextContent("Complete the secure setup yourself in Stripe");
    expect(screen.queryByRole("button", { name: "Withdraw" })).not.toBeInTheDocument();
    expect(screen.queryByText("Instant")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Update bank details" }));
    expect(onboard).toHaveBeenCalledOnce();
  });
  it("keeps an existing confirmation accessible after bank setup is reset", () => {
    const open = vi.fn();
    render(<StripePayoutsCard status={{ configured: true, has_account: false, status: "pending", payout_rail: "global", payouts_available: false }} confirmationPending withdrawals={[]} balanceMicroUsd={0} onboardLoading={false} selectedCountry="" onCountryChange={vi.fn()} onOnboard={vi.fn()} onOpenWithdraw={open} title="Bank withdrawals" noun="earnings" icon={null} className="" />);
    fireEvent.click(screen.getByRole("button", { name: "Check withdrawal" }));
    expect(open).toHaveBeenCalledOnce();
    expect(screen.queryByRole("button", { name: "Link bank via Stripe" })).not.toBeInTheDocument();
  });

});
