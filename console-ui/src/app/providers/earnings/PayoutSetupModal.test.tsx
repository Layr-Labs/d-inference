// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { PayoutSetupModal } from "./PayoutSetupModal";
import { makeStripeStatus } from "./testFixtures";

function renderModal(overrides: Partial<Parameters<typeof PayoutSetupModal>[0]> = {}) {
  const props = {
    status: makeStripeStatus({ has_account: false, status: "" as const }),
    onboardLoading: false,
    selectedCountry: "US",
    onCountryChange: vi.fn(),
    onOnboard: vi.fn(),
    onUnlink: vi.fn(),
    unlinkLoading: false,
    ...overrides,
  };
  render(<PayoutSetupModal {...props} />);
  return props;
}

describe("PayoutSetupModal", () => {
  it("offers link-bank onboarding when no account exists", () => {
    const props = renderModal();
    expect(screen.getByText(/Link a bank account or debit card/)).toBeInTheDocument();
    const btn = screen.getByRole("button", { name: /link bank via stripe/i });
    fireEvent.click(btn);
    expect(props.onOnboard).toHaveBeenCalledOnce();
    // No unlink escape hatch before an account exists.
    expect(screen.queryByText(/unlink stripe account/i)).toBeNull();
  });

  it("disables onboarding until a country is picked", () => {
    renderModal({ selectedCountry: "" });
    expect(
      screen.getByRole("button", { name: /link bank via stripe/i }),
    ).toBeDisabled();
    expect(screen.getByText(/Select your country to continue/)).toBeInTheDocument();
  });

  it("asks a restricted account for more info and offers unlink", () => {
    const props = renderModal({
      status: makeStripeStatus({ status: "restricted", stripe_account_country: "US" }),
    });
    expect(screen.getByText(/locked to/i)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /provide more info/i }));
    expect(props.onOnboard).toHaveBeenCalledOnce();
    fireEvent.click(screen.getByRole("button", { name: /unlink stripe account/i }));
    expect(props.onUnlink).toHaveBeenCalledOnce();
  });

  it("shows continue setup for a pending account", () => {
    renderModal({ status: makeStripeStatus({ status: "pending" }) });
    expect(screen.getByRole("button", { name: /continue setup/i })).toBeInTheDocument();
  });
});
