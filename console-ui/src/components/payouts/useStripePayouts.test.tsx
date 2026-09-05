import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { useStripePayouts } from "./useStripePayouts";
import { ApiError } from "@/lib/api/errors";

const api = vi.hoisted(() => ({ fetchStripeStatus: vi.fn(), fetchStripeWithdrawals: vi.fn(), fetchBankWithdrawalQuote: vi.fn(), withdrawStripe: vi.fn(), startStripeOnboarding: vi.fn(), createStripeDashboardLink: vi.fn(), unlinkStripeAccount: vi.fn() }));
vi.mock("@/lib/api", async () => ({ ...api, ApiError: (await import("@/lib/api/errors")).ApiError }));

afterEach(() => vi.restoreAllMocks());

const completeQuote = { id: "original-quote", amount_usd: "10.00", fee_usd: "0.00", destination_amount: 80000, currency: "inr", currency_exponent: 2, expires_at: "2099-01-01T00:00:00Z", destination_last4: "1234", eta: "Typically 1–7 business days" };

const testToast = vi.fn();

beforeEach(() => {
  localStorage.clear();
  vi.clearAllMocks();
  api.fetchStripeStatus.mockResolvedValue({ account_id: "provider-a", configured: true, has_account: true, status: "ready", payout_rail: "global", stripe_account_country: "IN" });
  api.fetchStripeWithdrawals.mockResolvedValue([]);
});

it("retries the same confirmation after a lost response even when its quote expires", async () => {
  const time = vi.spyOn(Date, "now"); time.mockReturnValue(1_800_000_000_000);
  api.fetchBankWithdrawalQuote.mockResolvedValue({ ...completeQuote, expires_at: new Date(Date.now() + 60_000).toISOString() });
  api.withdrawStripe.mockRejectedValueOnce(new Error("network response lost")).mockResolvedValueOnce({ status: "processing", method: "standard", payout_rail: "global" });
  const { result } = renderHook(() => useStripePayouts({ addToast: testToast }));
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
  api.fetchBankWithdrawalQuote.mockResolvedValue({ ...completeQuote, id: "balance-quote", expires_at: "2099-01-01T00:00:00Z" });
  api.withdrawStripe.mockRejectedValueOnce(new ApiError("Insufficient earnings", "insufficient_withdrawable", 400));
  const { result } = renderHook(() => useStripePayouts({ addToast: testToast }));
  await waitFor(() => expect(result.current.status?.status).toBe("ready"));
  await act(() => result.current.withdraw());
  await act(() => result.current.withdraw());
  expect(result.current.withdrawConfirmationPending).toBe(false);
  expect(result.current.withdrawQuote).toBeNull();
  act(() => result.current.setWithdrawAmount("5"));
  expect(result.current.withdrawAmount).toBe("5");
});


it("restores the original confirmation after a lost response and full remount", async () => {
  api.fetchBankWithdrawalQuote.mockResolvedValue(completeQuote);
  api.withdrawStripe.mockRejectedValueOnce(new Error("response lost")).mockResolvedValueOnce({status: "posted", method: "standard", payout_rail: "global"});
  const first = renderHook(() => useStripePayouts({addToast: testToast}));
  await waitFor(() => expect(first.result.current.status?.status).toBe("ready"));
  await act(() => first.result.current.withdraw());
  await act(() => first.result.current.withdraw());
  first.unmount();
  vi.spyOn(Date, "now").mockReturnValue(Date.parse("2100-01-01T00:00:00Z"));
  const second = renderHook(() => useStripePayouts({addToast: testToast}));
  await waitFor(() => expect(second.result.current.withdrawConfirmationPending).toBe(true));
  expect(second.result.current.withdrawQuote?.id).toBe(completeQuote.id);
  act(() => second.result.current.openWithdraw("20"));
  expect(Number(second.result.current.withdrawAmount)).toBe(10);
  await act(() => second.result.current.withdraw());
  expect(api.fetchBankWithdrawalQuote).toHaveBeenCalledTimes(1);
  expect(api.withdrawStripe).toHaveBeenNthCalledWith(2, "10.00", "standard", completeQuote.id);
  expect(localStorage.length).toBe(0);
});

it("keeps saved confirmations scoped to the authenticated account", async () => {
  api.fetchBankWithdrawalQuote.mockResolvedValue(completeQuote);
  api.withdrawStripe.mockRejectedValueOnce(new Error("response lost"));
  const first = renderHook(() => useStripePayouts({addToast: testToast}));
  await waitFor(() => expect(first.result.current.status?.status).toBe("ready"));
  await act(() => first.result.current.withdraw());
  await act(() => first.result.current.withdraw());
  first.unmount();
  api.fetchStripeStatus.mockResolvedValue({account_id:"provider-b",configured:true,has_account:true,status:"ready",payout_rail:"global"});
  const second = renderHook(() => useStripePayouts({addToast:testToast}));
  await waitFor(() => expect(second.result.current.status?.account_id).toBe("provider-b"));
  expect(second.result.current.withdrawConfirmationPending).toBe(false);
  expect(second.result.current.withdrawQuote).toBeNull();
  expect(api.withdrawStripe).toHaveBeenCalledTimes(1);
  expect(localStorage.length).toBe(1);
});

it("does not send a confirmation unless its identity was saved successfully", async () => {
  api.fetchBankWithdrawalQuote.mockResolvedValue(completeQuote);
  const { result } = renderHook(() => useStripePayouts({addToast:testToast}));
  await waitFor(() => expect(result.current.status?.status).toBe("ready"));
  await act(() => result.current.withdraw());
  vi.spyOn(localStorage,"setItem").mockImplementation(() => { throw new Error("storage unavailable"); });
  await act(() => result.current.withdraw());
  expect(api.withdrawStripe).not.toHaveBeenCalled();
});

it("blocks new quotes if saved confirmation recovery cannot be read", async () => {
  vi.spyOn(localStorage,"getItem").mockImplementation(() => { throw new Error("storage unavailable"); });
  const toast=vi.fn();
  const { result }=renderHook(() => useStripePayouts({addToast:toast}));
  await waitFor(() => expect(api.fetchStripeStatus).toHaveBeenCalled());
  await act(() => result.current.withdraw());
  expect(api.fetchBankWithdrawalQuote).not.toHaveBeenCalled();
  expect(api.withdrawStripe).not.toHaveBeenCalled();
});
