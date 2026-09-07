import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ReferralAttributionProvider, useReferralAttribution } from "./ReferralAttributionProvider";
import { readReferral } from "./attribution";

const mocks = vi.hoisted(() => ({
  auth: { ready: true, authenticated: false, user: null as { id: string } | null, getAccessToken: vi.fn() },
  apply: vi.fn(),
}));
vi.mock("@/components/providers/PrivyClientProvider", () => ({ useAuthContext: () => mocks.auth }));
vi.mock("@/lib/api/referrals", () => ({ applyReferral: mocks.apply }));
vi.mock("next/navigation", () => ({ usePathname: () => "/" }));

function Status() {
  const referral = useReferralAttribution();
  return <><span>{referral.code}</span><span>{referral.status}</span><span>{referral.error}</span><button onClick={() => referral.apply()}>Retry</button></>;
}

describe("referral application after login", () => {
  beforeEach(() => {
    vi.clearAllMocks(); localStorage.clear(); window.history.replaceState({}, "", "/?ref=ALICE");
    mocks.auth.authenticated = false; mocks.auth.user = null;
    mocks.auth.getAccessToken.mockResolvedValue("privy-token");
    mocks.apply.mockResolvedValue({ status: "applied", code: "ALICE" });
  });
  afterEach(cleanup);

  it("retains the link before login, then applies once with the Privy token", async () => {
    const tree = <ReferralAttributionProvider><Status /></ReferralAttributionProvider>;
    const { rerender } = render(tree);
    expect(readReferral()).toBe("ALICE"); expect(mocks.apply).not.toHaveBeenCalled();
    mocks.auth.authenticated = true; mocks.auth.user = { id: "user-a" };
    rerender(<ReferralAttributionProvider><Status /></ReferralAttributionProvider>);
    await waitFor(() => expect(screen.getByText("applied")).toBeInTheDocument());
    expect(mocks.apply).toHaveBeenCalledExactlyOnceWith("privy-token", "ALICE");
    expect(readReferral()).toBeNull();
  });

  it("keeps attribution on errors and permits an explicit retry", async () => {
    mocks.auth.authenticated = true; mocks.auth.user = { id: "user-a" };
    mocks.apply.mockRejectedValueOnce(new Error("Temporarily unavailable"));
    render(<ReferralAttributionProvider><Status /></ReferralAttributionProvider>);
    await screen.findByText("Temporarily unavailable");
    expect(readReferral()).toBe("ALICE"); expect(mocks.apply).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByText("Retry"));
    await screen.findByText("applied");
    expect(mocks.apply).toHaveBeenCalledTimes(2); expect(readReferral()).toBeNull();
  });

  it("does not apply using a mock login with no real account", async () => {
    mocks.auth.authenticated = true;
    render(<ReferralAttributionProvider><Status /></ReferralAttributionProvider>);
    await act(async () => {});
    expect(mocks.auth.getAccessToken).not.toHaveBeenCalled(); expect(readReferral()).toBe("ALICE");
  });

  it("does not carry a successful attribution into a different account", async () => {
    mocks.auth.authenticated = true; mocks.auth.user = { id: "user-a" };
    const { rerender } = render(<ReferralAttributionProvider><Status /></ReferralAttributionProvider>);
    await screen.findByText("applied");
    mocks.auth.user = { id: "user-b" };
    rerender(<ReferralAttributionProvider><Status /></ReferralAttributionProvider>);
    await waitFor(() => expect(screen.queryByText("applied")).not.toBeInTheDocument());
    expect(screen.queryByText("ALICE")).not.toBeInTheDocument();
    expect(mocks.apply).toHaveBeenCalledTimes(1);
  });

  it("ignores an old account's completion and retries retained attribution for the new account", async () => {
    let finish!: (value: { status: string; code: string }) => void;
    mocks.auth.authenticated = true; mocks.auth.user = { id: "user-a" };
    mocks.apply.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    const { rerender } = render(<ReferralAttributionProvider><Status /></ReferralAttributionProvider>);
    await waitFor(() => expect(mocks.apply).toHaveBeenCalledTimes(1));
    mocks.auth.user = { id: "user-b" };
    rerender(<ReferralAttributionProvider><Status /></ReferralAttributionProvider>);
    await act(async () => { finish({ status: "applied", code: "ALICE" }); });
    await waitFor(() => expect(mocks.apply).toHaveBeenCalledTimes(2));
    expect(screen.getByText("applied")).toBeInTheDocument();
  });
});
