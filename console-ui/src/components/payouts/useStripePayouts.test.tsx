import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, expect, it, vi } from "vitest";
import { useStripePayouts } from "./useStripePayouts";
import { ApiError } from "@/lib/api/errors";

const api = vi.hoisted(() => ({ fetchStripeStatus: vi.fn(), fetchStripeWithdrawals: vi.fn(), fetchBankWithdrawalQuote: vi.fn(), withdrawStripe: vi.fn(), startStripeOnboarding: vi.fn(), createStripeDashboardLink: vi.fn(), unlinkStripeAccount: vi.fn() }));
vi.mock("@/lib/api", async () => ({ ...api, ApiError: (await import("@/lib/api/errors")).ApiError }));

beforeEach(() => {
  vi.clearAllMocks();
  api.fetchStripeStatus.mockResolvedValue({ configured: true, has_account: true, status: "ready", payout_rail: "global", stripe_account_country: "IN" });
  api.fetchStripeWithdrawals.mockResolvedValue([]);
});

it("retries the same confirmation after a lost response even when its quote expires", async () => {
  const time = vi.spyOn(Date, "now"); time.mockReturnValue(1_800_000_000_000);
  api.fetchBankWithdrawalQuote.mockResolvedValue({ id: "original-quote", amount_usd: "10.00", expires_at: new Date(Date.now() + 60_000).toISOString() });
  api.withdrawStripe.mockRejectedValueOnce(new Error("network response lost")).mockResolvedValueOnce({ status: "processing", method: "standard", payout_rail: "global" });
  const { result } = renderHook(() => useStripePayouts({ addToast: vi.fn() }));
  await waitFor(() => expect(result.current.status?.status).toBe("ready"));
  await act(() => result.current.withdraw()); // review
  expect(api.withdrawStripe).not.toHaveBeenCalled();
  await act(() => result.current.withdraw()); // confirm, response lost
  expect(result.current.withdrawConfirmationPending).toBe(true);
  time.mockReturnValue(1_800_000_120_000);
  await act(() => result.current.withdraw()); // resolve original intent
  expect(api.fetchBankWithdrawalQuote).toHaveBeenCalledTimes(1);
  expect(api.withdrawStripe).toHaveBeenNthCalledWith(1, "10", "standard", "original-quote");
  expect(api.withdrawStripe).toHaveBeenNthCalledWith(2, "10", "standard", "original-quote");
  expect(result.current.withdrawConfirmationPending).toBe(false);
  time.mockRestore();
});


it("allows a smaller amount after the balance changed before confirmation", async () => {
  api.fetchBankWithdrawalQuote.mockResolvedValue({ id: "balance-quote", amount_usd: "10.00", expires_at: "2099-01-01T00:00:00Z" });
  api.withdrawStripe.mockRejectedValueOnce(new ApiError("Insufficient earnings", "insufficient_withdrawable", 400));
  const { result } = renderHook(() => useStripePayouts({ addToast: vi.fn() }));
  await waitFor(() => expect(result.current.status?.status).toBe("ready"));
  await act(() => result.current.withdraw());
  await act(() => result.current.withdraw());
  expect(result.current.withdrawConfirmationPending).toBe(false);
  expect(result.current.withdrawQuote).toBeNull();
  act(() => result.current.setWithdrawAmount("5"));
  expect(result.current.withdrawAmount).toBe("5");
});
