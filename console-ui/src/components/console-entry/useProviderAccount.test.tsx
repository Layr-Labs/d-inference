import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useProviderAccount } from "./useProviderAccount";

const auth = vi.hoisted(() => ({
  ready: true,
  authenticated: true,
  user: { id: "account-a" } as { id: string } | null,
  getAccessToken: vi.fn<() => Promise<string | null>>(),
}));
vi.mock("@/components/providers/PrivyClientProvider", () => ({ useAuthContext: () => auth }));
const upstreamFetch = vi.fn<typeof fetch>();

function deferred<T>() {
  let complete!: (value: T) => void;
  const promise = new Promise<T>((resolve) => { complete = resolve; });
  return { promise, resolve: complete };
}

beforeEach(() => {
  vi.useFakeTimers();
  auth.ready = true;
  auth.authenticated = true;
  auth.user = { id: "account-a" };
  auth.getAccessToken.mockReset().mockResolvedValue("session-a");
  upstreamFetch.mockReset().mockResolvedValue(Response.json({ providers: [] }));
  vi.stubGlobal("fetch", upstreamFetch);
  Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true });
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("useProviderAccount", () => {
  it("keeps unresolved auth loading, then shows guests without requesting credentials or providers", async () => {
    auth.ready = false;
    auth.authenticated = false;
    auth.user = null;
    const { result, rerender } = renderHook(() => useProviderAccount(true));
    expect(result.current.account.status).toBe("loading");
    auth.ready = true;
    rerender();
    await act(async () => {});
    expect(result.current.account).toEqual({ status: "guest", total: 0, online: 0 });
    expect(auth.getAccessToken).not.toHaveBeenCalled();
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("waits until enabled and distinguishes a verified empty account from loading", async () => {
    const response = deferred<Response>();
    upstreamFetch.mockReturnValue(response.promise);
    const { result, rerender } = renderHook(({ enabled }) => useProviderAccount(enabled), { initialProps: { enabled: false } });
    await act(async () => {});
    expect(upstreamFetch).not.toHaveBeenCalled();
    rerender({ enabled: true });
    await act(async () => {});
    expect(result.current.account.status).toBe("loading");
    expect(upstreamFetch).toHaveBeenCalledWith("/api/me/providers", {
      headers: { Authorization: "Bearer session-a" }, cache: "no-store", signal: expect.any(AbortSignal),
    });
    await act(async () => { response.resolve(Response.json({ providers: [] })); });
    expect(result.current.account).toEqual({ status: "new", total: 0, online: 0 });
    expect(vi.getTimerCount()).toBe(0);
  });

  it("recognizes linked offline machines and refreshes their online count on visibility return", async () => {
    upstreamFetch.mockResolvedValueOnce(Response.json({ providers: [{ id: "mac-a", online: false }, { id: "mac-b" }] }));
    const { result } = renderHook(() => useProviderAccount(true));
    await act(async () => {});
    expect(result.current.account).toEqual({ status: "linked", total: 2, online: 0 });
    upstreamFetch.mockResolvedValueOnce(Response.json({ providers: [{ id: "mac-a", online: true }, { id: "mac-b", online: false }] }));
    await act(async () => { document.dispatchEvent(new Event("visibilitychange")); });
    expect(result.current.account).toEqual({ status: "linked", total: 2, online: 1 });
  });

  it.each([{}, { providers: null }, { providers: [{}] }, { providers: [{ id: 12 }] }])("does not present invalid successful data as a new account: %j", async (payload) => {
    upstreamFetch.mockResolvedValueOnce(Response.json(payload));
    const { result } = renderHook(() => useProviderAccount(true));
    await act(async () => {});
    expect(result.current.account).toEqual({ status: "error", total: 0, online: 0 });
  });

  it("reports an upstream failure as unknown and allows an explicit retry to recover", async () => {
    upstreamFetch.mockResolvedValueOnce(new Response(null, { status: 503 }));
    const { result } = renderHook(() => useProviderAccount(true));
    await act(async () => {});
    expect(result.current.account.status).toBe("error");
    upstreamFetch.mockResolvedValueOnce(Response.json({ providers: [{ id: "mac-a", online: true }] }));
    await act(async () => { result.current.retry(); });
    expect(result.current.account).toEqual({ status: "linked", total: 1, online: 1 });
    expect(auth.getAccessToken).toHaveBeenCalledTimes(2);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("clears another account's result and ignores its late refresh after account switching", async () => {
    const oldRefresh = deferred<Response>();
    upstreamFetch.mockResolvedValueOnce(Response.json({ providers: [{ id: "old-mac", online: true }] }));
    const { result, rerender } = renderHook(() => useProviderAccount(true));
    await act(async () => {});
    expect(result.current.account.status).toBe("linked");
    upstreamFetch.mockReturnValueOnce(oldRefresh.promise);
    await act(async () => { document.dispatchEvent(new Event("visibilitychange")); });
    const abandonedSignal = upstreamFetch.mock.calls[1][1]?.signal;
    const newResponse = deferred<Response>();
    upstreamFetch.mockReturnValueOnce(newResponse.promise);
    auth.user = { id: "account-b" };
    auth.getAccessToken.mockResolvedValue("session-b");
    rerender();
    expect(result.current.account).toEqual({ status: "loading", total: 0, online: 0 });
    expect(abandonedSignal?.aborted).toBe(true);
    await act(async () => { newResponse.resolve(Response.json({ providers: [] })); });
    expect(result.current.account.status).toBe("new");
    expect(upstreamFetch.mock.calls[2][1]?.headers).toEqual({ Authorization: "Bearer session-b" });
    // Deliberately complete a mock that ignores abort to prove result isolation.
    await act(async () => { oldRefresh.resolve(Response.json({ providers: [{ id: "old-mac", online: true }] })); });
    expect(result.current.account).toEqual({ status: "new", total: 0, online: 0 });
  });

  it("cancels logout requests and prevents late credentials from starting a provider lookup", async () => {
    const token = deferred<string | null>();
    auth.getAccessToken.mockReturnValueOnce(token.promise);
    const { result, rerender } = renderHook(() => useProviderAccount(true));
    auth.authenticated = false;
    auth.user = null;
    rerender();
    expect(result.current.account.status).toBe("guest");
    await act(async () => { token.resolve("old-session"); });
    expect(upstreamFetch).not.toHaveBeenCalled();
    expect(result.current.account.status).toBe("guest");
    expect(vi.getTimerCount()).toBe(0);
  });

  it("ignores a provider response completed after logout", async () => {
    const response = deferred<Response>();
    upstreamFetch.mockReturnValueOnce(response.promise);
    const { result, rerender } = renderHook(() => useProviderAccount(true));
    await act(async () => {});
    const signal = upstreamFetch.mock.calls[0][1]?.signal;
    auth.authenticated = false;
    auth.user = null;
    rerender();
    expect(signal?.aborted).toBe(true);
    await act(async () => { response.resolve(Response.json({ providers: [{ id: "old-mac", online: true }] })); });
    expect(result.current.account).toEqual({ status: "guest", total: 0, online: 0 });
  });

  it("bounds stalled token acquisition and allows retry without accepting late credentials", async () => {
    const token = deferred<string | null>();
    auth.getAccessToken.mockReturnValueOnce(token.promise);
    const { result } = renderHook(() => useProviderAccount(true));
    await act(async () => { vi.advanceTimersByTime(14_999); });
    expect(result.current.account.status).toBe("loading");
    await act(async () => { vi.advanceTimersByTime(1); });
    expect(result.current.account.status).toBe("error");
    expect(upstreamFetch).not.toHaveBeenCalled();
    await act(async () => { result.current.retry(); });
    expect(result.current.account.status).toBe("new");
    await act(async () => { token.resolve("expired-session"); });
    expect(upstreamFetch).toHaveBeenCalledTimes(1);
    expect(result.current.account.status).toBe("new");
    expect(vi.getTimerCount()).toBe(0);
  });

  it("aborts a stalled fetch at 15 seconds and ignores a response arriving after its deadline", async () => {
    const response = deferred<Response>();
    upstreamFetch.mockReturnValueOnce(response.promise);
    const { result } = renderHook(() => useProviderAccount(true));
    await act(async () => {});
    const signal = upstreamFetch.mock.calls[0][1]?.signal;
    await act(async () => { vi.advanceTimersByTime(15_000); });
    expect(signal?.aborted).toBe(true);
    expect(result.current.account.status).toBe("error");
    await act(async () => { response.resolve(Response.json({ providers: [{ id: "too-late", online: true }] })); });
    expect(result.current.account.status).toBe("error");
    await act(async () => { result.current.retry(); });
    expect(result.current.account.status).toBe("new");
  });
});
