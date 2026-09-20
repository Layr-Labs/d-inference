import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ReferralRegistration } from "./ReferralRegistration";

const register = vi.hoisted(() => vi.fn());
vi.mock("@/lib/api/referrals", () => ({ registerReferral: register }));

describe("referral registration account isolation", () => {
  afterEach(() => { cleanup(); vi.clearAllMocks(); });

  function submitCode() {
    fireEvent.change(screen.getByLabelText("Your referral code"), { target: { value: "alice" } });
    fireEvent.click(screen.getByRole("button", { name: "Create referral link" }));
  }

  it("does not register the old account's code with a new account's token", async () => {
    let resolveToken!: (token: string) => void;
    const getToken = () => new Promise<string>((resolve) => { resolveToken = resolve; });
    const refreshA = vi.fn(); const refreshB = vi.fn();
    const { rerender } = render(<ReferralRegistration accountID="a" getAccessToken={getToken} onRegistered={refreshA} />);
    submitCode();
    rerender(<ReferralRegistration accountID="b" getAccessToken={getToken} onRegistered={refreshB} />);
    await act(async () => { resolveToken("token-b"); });
    expect(register).not.toHaveBeenCalled(); expect(refreshA).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Create referral link" })).toBeEnabled();
  });

  it("does not run the old refresh when an in-flight registration completes after a switch", async () => {
    let resolvePost!: (value: { code: string }) => void;
    register.mockImplementationOnce(() => new Promise((resolve) => { resolvePost = resolve; }));
    const getToken = async () => "token-a";
    const refreshA = vi.fn(); const refreshB = vi.fn();
    const { rerender } = render(<ReferralRegistration accountID="a" getAccessToken={getToken} onRegistered={refreshA} />);
    submitCode();
    await waitFor(() => expect(register).toHaveBeenCalledWith("token-a", "ALICE"));
    rerender(<ReferralRegistration accountID="b" getAccessToken={getToken} onRegistered={refreshB} />);
    await act(async () => { resolvePost({ code: "ALICE" }); });
    expect(refreshA).not.toHaveBeenCalled(); expect(refreshB).not.toHaveBeenCalled();
  });
});
