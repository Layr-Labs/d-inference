import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useReferralAccount } from "./useReferralAccount";

const mocks = vi.hoisted(() => ({ info: vi.fn(), stats: vi.fn() }));
vi.mock("@/lib/api/referrals", () => ({ fetchReferralInfo: mocks.info, fetchReferralStats: mocks.stats }));

describe("referral account refresh isolation", () => {
  afterEach(() => { cleanup(); vi.clearAllMocks(); });

  it("ignores a saved refresh callback after switching account", async () => {
    mocks.info.mockImplementation(async (token: string) => ({ code: token, referred_by: "" }));
    mocks.stats.mockImplementation(async (token: string) => ({ code: token }));
    const getTokenA = vi.fn().mockResolvedValue("A"); const getTokenB = vi.fn().mockResolvedValue("B");
    const { result, rerender } = renderHook(({ account, getToken }) => useReferralAccount(account, getToken, "pending"), { initialProps: { account: "a", getToken: getTokenA } });
    await waitFor(() => expect(result.current.info?.code).toBe("A"));
    const staleRefresh = result.current.refresh;
    rerender({ account: "b", getToken: getTokenB });
    await waitFor(() => expect(result.current.info?.code).toBe("B"));
    await act(async () => { await staleRefresh(); });
    expect(result.current.info?.code).toBe("B"); expect(result.current.loading).toBe(false);
    expect(getTokenA).toHaveBeenCalledTimes(1);
  });
});
