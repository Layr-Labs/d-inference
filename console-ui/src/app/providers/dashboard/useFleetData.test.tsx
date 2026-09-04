import { StrictMode, type ReactNode } from "react";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useFleetData, type FleetData } from "./useFleetData";
import { makeProvider } from "./testFixtures";

const auth = vi.hoisted(() => ({
  ready: true, authenticated: true,
  unstableGetter: false,
  user: { id: "account-a" } as { id: string } | null,
  login: vi.fn(), getAccessToken: vi.fn(async () => "token-a" as string | null),
}));
vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => auth.unstableGetter
    ? { ...auth, getAccessToken: async () => auth.getAccessToken() }
    : auth,
}));
function deferred<T>() {
  let complete!: (value: T) => void;
  const promise = new Promise<T>((resolve) => { complete = resolve; });
  return { promise, resolve: complete };
}
function fleet(id: string) {
  return { providers: [makeProvider({ id })], latest_provider_version: "1.0.0", min_provider_version: "1.0.0", heartbeat_timeout_seconds: 90, challenge_max_age_seconds: 360 };
}
const response = (value: unknown) => ({ ok: true, json: async () => value }) as Response;
const summaryFailure = () => Promise.resolve({ ok: false, status: 503 } as Response);

beforeEach(() => {
  auth.ready = true; auth.authenticated = true; auth.user = { id: "account-a" };
  auth.unstableGetter = false;
  auth.getAccessToken.mockReset().mockResolvedValue("token-a");
});
afterEach(() => { cleanup(); vi.useRealTimers(); vi.unstubAllGlobals(); });

describe("account-scoped fleet loading", () => {
  it("does not restart account loading when the token getter changes every render", async () => {
    auth.unstableGetter = true;
    const pending = deferred<Response>();
    const fetchMock = vi.fn((url: string, _options: RequestInit) => url.endsWith("providers") ? pending.promise : summaryFailure());
    vi.stubGlobal("fetch", fetchMock);
    const { result, rerender } = renderHook(() => useFleetData());
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    const signal = fetchMock.mock.calls[0][1].signal;
    rerender(); rerender();
    expect(signal?.aborted).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await act(async () => pending.resolve(response(fleet("machine-a"))));
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.providersResp?.providers[0].id).toBe("machine-a");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    auth.getAccessToken.mockResolvedValue("updated-token");
    rerender();
    await act(async () => result.current.refetch());
    expect(fetchMock).toHaveBeenCalledTimes(4);
    expect(fetchMock.mock.calls[2][1].headers).toEqual({ Authorization: "Bearer updated-token" });
  });

  it("shows loading on every first sign-in render until the fleet is known", async () => {
    auth.authenticated = false; auth.user = null;
    const pending = deferred<Response>();
    const fetchMock = vi.fn((url: string) => url.endsWith("providers") ? pending.promise : summaryFailure());
    vi.stubGlobal("fetch", fetchMock);
    const renders: FleetData[] = [];
    const { result, rerender } = renderHook(() => { const data = useFleetData(); renders.push(data); return data; });
    expect(fetchMock).not.toHaveBeenCalled();
    auth.authenticated = true; auth.user = { id: "account-a" }; rerender();
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(renders.filter((data) => data.authenticated).every((data) => data.loading)).toBe(true);
    await act(async () => pending.resolve(response({ ...fleet("unused"), providers: [] })));
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.providersResp?.providers).toEqual([]);
    expect(result.current.error).toBeNull();
  });

  it("clears fleet and summary on the first account-switch render and loads the new account", async () => {
    const nextFleet = deferred<Response>();
    const fetchMock = vi.fn((url: string, options: RequestInit) => {
      const first = (options.headers as { Authorization: string }).Authorization === "Bearer token-a";
      if (url.endsWith("summary")) return Promise.resolve(response({ account_id: first ? "account-a" : "account-b" }));
      return first ? Promise.resolve(response(fleet("machine-a"))) : nextFleet.promise;
    });
    vi.stubGlobal("fetch", fetchMock);
    const renders: FleetData[] = [];
    const { result, rerender } = renderHook(() => { const data = useFleetData(); renders.push(data); return data; });
    await waitFor(() => expect(result.current.summary?.account_id).toBe("account-a"));
    renders.length = 0;
    auth.user = { id: "account-b" }; auth.getAccessToken.mockResolvedValue("token-b"); rerender();
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(4));
    expect(renders.every((data) => data.providersResp === null && data.summary === null && data.loading)).toBe(true);
    await act(async () => nextFleet.resolve(response(fleet("machine-b"))));
    await waitFor(() => expect(result.current.providersResp?.providers[0].id).toBe("machine-b"));
    expect(result.current.summary?.account_id).toBe("account-b");
  });

  it("aborts and ignores stale requests after logout and re-login to the same account", async () => {
    const oldFleet = deferred<Response>(); const newFleet = deferred<Response>();
    let providerLoads = 0;
    const fetchMock = vi.fn((url: string, _options: RequestInit) => {
      if (url.endsWith("summary")) return summaryFailure();
      return ++providerLoads === 1 ? oldFleet.promise : newFleet.promise;
    });
    vi.stubGlobal("fetch", fetchMock);
    const { result, rerender } = renderHook(() => useFleetData());
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    const oldSignal = fetchMock.mock.calls[0][1].signal;
    auth.authenticated = false; rerender();
    expect(oldSignal?.aborted).toBe(true);
    expect(result.current.providersResp).toBeNull(); expect(result.current.loading).toBe(false);
    auth.authenticated = true; rerender();
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(4));
    await act(async () => oldFleet.resolve(response(fleet("stale-machine"))));
    expect(result.current.providersResp).toBeNull(); expect(result.current.loading).toBe(true);
    await act(async () => newFleet.resolve(response(fleet("current-machine"))));
    await waitFor(() => expect(result.current.providersResp?.providers[0].id).toBe("current-machine"));
  });

  it("ignores old JSON parsing that completes after another account loads", async () => {
    const oldBody = deferred<ReturnType<typeof fleet>>(); const json = vi.fn(() => oldBody.promise);
    vi.stubGlobal("fetch", vi.fn((url: string, options: RequestInit) => {
      if (url.endsWith("summary")) return summaryFailure();
      return Promise.resolve((options.headers as { Authorization: string }).Authorization === "Bearer token-a"
        ? { ok: true, json } as unknown as Response : response(fleet("machine-b")));
    }));
    const { result, rerender } = renderHook(() => useFleetData());
    await waitFor(() => expect(json).toHaveBeenCalledOnce());
    auth.user = { id: "account-b" }; auth.getAccessToken.mockResolvedValue("token-b"); rerender();
    await waitFor(() => expect(result.current.providersResp?.providers[0].id).toBe("machine-b"));
    await act(async () => oldBody.resolve(fleet("machine-a")));
    expect(result.current.providersResp?.providers[0].id).toBe("machine-b");
  });

  it("coalesces manual refresh and polling while the first request is pending", async () => {
    vi.useFakeTimers();
    const pending = deferred<Response>();
    const fetchMock = vi.fn((url: string) => url.endsWith("providers") ? pending.promise : summaryFailure());
    vi.stubGlobal("fetch", fetchMock);
    const { result } = renderHook(() => useFleetData());
    await act(async () => {});
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await act(async () => {
      result.current.refetch(); result.current.refetch();
      await vi.advanceTimersByTimeAsync(45_000);
      document.dispatchEvent(new Event("visibilitychange"));
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await act(async () => pending.resolve(response(fleet("machine-a"))));
    await act(async () => { await vi.advanceTimersByTimeAsync(15_000); });
    expect(fetchMock).toHaveBeenCalledTimes(4);
  });

  it("survives Strict Mode effect replay and cancels pending work on unmount", async () => {
    const pending = deferred<Response>();
    const fetchMock = vi.fn((url: string, _options: RequestInit) => url.endsWith("providers") ? pending.promise : summaryFailure());
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = ({ children }: { children: ReactNode }) => <StrictMode>{children}</StrictMode>;
    const { result, unmount } = renderHook(() => useFleetData(), { wrapper });
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(result.current.refreshing).toBe(true);
    const signal = fetchMock.mock.calls[0][1].signal;
    unmount(); expect(signal?.aborted).toBe(true);
    await act(async () => pending.resolve(response(fleet("unmounted-machine"))));
  });

  it("retains dated data after a failed refresh and rejects malformed initial data", async () => {
    let calls = 0;
    vi.stubGlobal("fetch", vi.fn((url: string) => {
      if (url.endsWith("summary")) return summaryFailure();
      return Promise.resolve(response(++calls === 1 ? fleet("machine-a") : {}));
    }));
    const { result, rerender } = renderHook(() => useFleetData());
    await waitFor(() => expect(result.current.loading).toBe(false));
    const timestamp = result.current.lastUpdatedAt;
    await act(async () => result.current.refetch());
    expect(result.current.pollFailed).toBe(true);
    expect(result.current.providersResp?.providers[0].id).toBe("machine-a");
    expect(result.current.lastUpdatedAt).toBe(timestamp); expect(result.current.error).toBeNull();
    auth.user = { id: "account-b" }; rerender();
    await waitFor(() => expect(result.current.error).toBe("Invalid provider response"));
    expect(result.current.providersResp).toBeNull(); expect(result.current.lastUpdatedAt).toBeNull();
    expect(result.current.pollFailed).toBe(false);
  });
});
