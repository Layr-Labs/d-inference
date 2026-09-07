import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import ReferralPage from "./page";
import { ApiError } from "@/lib/api/errors";

const mocks = vi.hoisted(() => ({
  auth: { ready: true, authenticated: true, user: { id: "alice" }, getAccessToken: vi.fn(), login: vi.fn() },
  info: vi.fn(), stats: vi.fn(), register: vi.fn(),
  attribution: { code: null as string | null, status: "idle", error: null, apply: vi.fn(), dismiss: vi.fn() },
}));
vi.mock("@/components/providers/PrivyClientProvider", () => ({ useAuthContext: () => mocks.auth }));
vi.mock("@/components/TopBar", () => ({ TopBar: () => null }));
vi.mock("@/lib/api/referrals", () => ({ fetchReferralInfo: mocks.info, fetchReferralStats: mocks.stats, registerReferral: mocks.register }));
vi.mock("@/components/referrals/ReferralAttributionProvider", () => ({ useReferralAttribution: () => mocks.attribution }));

describe("referral page", () => {
  beforeEach(() => {
    vi.clearAllMocks(); mocks.auth.authenticated = true; mocks.auth.getAccessToken.mockResolvedValue("privy-token");
    mocks.attribution.code = null; mocks.attribution.status = "idle";
    mocks.info.mockResolvedValue({ code: "", referred_by: "", share_percent: 5, reward_basis: "consumer_spend" });
    mocks.stats.mockRejectedValue(new ApiError("not registered", "referral_error", 404));
  });
  afterEach(cleanup);

  it("explains 5% of token spend and offers login without fetching account data", () => {
    mocks.auth.authenticated = false; render(<ReferralPage />);
    expect(screen.getByText(/5% of their token spend/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Sign in to get your link" }));
    expect(mocks.auth.login).toHaveBeenCalledOnce(); expect(mocks.info).not.toHaveBeenCalled();
  });

  it("offers custom registration without treating the expected stats 404 as failure", async () => {
    render(<ReferralPage />);
    expect(await screen.findByLabelText("Your referral code")).toBeInTheDocument();
    expect(screen.getByLabelText("Referral code you received")).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("shows registered earnings and attribution with no replacement form", async () => {
    mocks.info.mockResolvedValue({ code: "ALICE", referred_by: "BOB", share_percent: 5, reward_basis: "consumer_spend" });
    mocks.stats.mockResolvedValue({ code: "ALICE", total_referred: 2, total_rewards_usd: "0.050000", total_referred_spend_usd: "1.000000", balance_usd: "0.100000" });
    render(<ReferralPage />);
    const shareLink = await screen.findByLabelText("Your referral link");
    await waitFor(() => expect(shareLink).toHaveValue(`${window.location.origin}/referrals?ref=ALICE`));
    expect(screen.getByText("$0.050000")).toBeInTheDocument();
    expect(screen.getByText(/Referred by BOB/)).toBeInTheDocument();
    expect(screen.queryByLabelText("Referral code you received")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: /Manage withdrawals/ })).toHaveAttribute("href", "/billing");
  });

  it("keeps service failure distinct from an unregistered account and supports retry", async () => {
    mocks.info.mockRejectedValueOnce(new Error("Service unavailable"));
    render(<ReferralPage />);
    expect(await screen.findByRole("alert")).toHaveTextContent("Service unavailable");
    expect(screen.queryByLabelText("Your referral code")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByLabelText("Your referral code")).toBeInTheDocument();
  });

  it("normalizes registration and displays conflicts without losing the typed code", async () => {
    mocks.register.mockRejectedValue(new Error("Code is already taken"));
    render(<ReferralPage />);
    const input = await screen.findByLabelText("Your referral code");
    fireEvent.change(input, { target: { value: "my-code" } });
    fireEvent.click(screen.getByRole("button", { name: "Create referral link" }));
    await waitFor(() => expect(mocks.register).toHaveBeenCalledWith("privy-token", "MY-CODE"));
    expect(await screen.findByText("Code is already taken")).toBeInTheDocument();
    expect(input).toHaveValue("my-code");
  });

  it("lets an already-attributed account dismiss an incompatible saved link", async () => {
    mocks.attribution.code = "ALICE"; mocks.attribution.status = "error";
    mocks.info.mockResolvedValue({ code: "", referred_by: "BOB", share_percent: 5, reward_basis: "consumer_spend" });
    render(<ReferralPage />);
    expect(await screen.findByText(/The saved code ALICE cannot replace/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Remove saved code" }));
    expect(mocks.attribution.dismiss).toHaveBeenCalledOnce();
  });
});
