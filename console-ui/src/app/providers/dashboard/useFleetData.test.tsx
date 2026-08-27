// @vitest-environment jsdom
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useFleetData } from "./useFleetData";

const PROVIDER_A = "provider-a";

const auth = vi.hoisted(() => ({
  current: {
    ready: true,
    authenticated: true,
    user: { id: "account-a" },
    login: vi.fn(),
    getAccessToken: vi.fn().mockResolvedValue("token-a"),
  },
}));

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => auth.current,
}));

vi.mock("@/hooks/useVisiblePolling", () => ({
  useVisiblePolling: () => undefined,
}));

function response(body: unknown): Response {
  return {
    ok: true,
    status: 200,
    json: vi.fn().mockResolvedValue(body),
  } as unknown as Response;
}

describe("useFleetData", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
    auth.current = {
      ready: true,
      authenticated: true,
      user: { id: "account-a" },
      login: vi.fn(),
      getAccessToken: vi.fn().mockResolvedValue("token-a"),
    };
  });

  it("never exposes one account's fleet after the identity changes", async () => {
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValueOnce(response({ providers: [{ id: PROVIDER_A }] }))
        .mockResolvedValueOnce(response({ total_earnings: 10 }))
        .mockResolvedValueOnce(response({ attempts: [{ provider_id: PROVIDER_A }] }))
    );
    const { result, rerender } = renderHook(() => useFleetData());
    await act(async () => {
      await result.current.refetch();
    });
    await waitFor(() => {
      expect(result.current.providersResp).toMatchObject({
        providers: [{ id: PROVIDER_A }],
      });
    });

    auth.current = {
      ready: true,
      authenticated: true,
      user: { id: "account-b" },
      login: vi.fn(),
      getAccessToken: vi.fn().mockResolvedValue("token-b"),
    };
    rerender();

    expect(result.current.providersResp).toBeNull();
    expect(result.current.summary).toBeNull();
    expect(result.current.admissionAttempts).toEqual([]);
  });

  it("ignores a failed request owned by the previous account", async () => {
    let rejectProviders = (_reason?: unknown): void => undefined;
    const delayedProviders = new Promise<Response>((_resolve, reject) => {
      rejectProviders = reject;
    });
    const fetchMock = vi.fn((input: RequestInfo | URL) =>
      String(input).includes("/api/me/providers")
        ? delayedProviders
        : Promise.resolve(response({}))
    );
    vi.stubGlobal("fetch", fetchMock);
    const { result, rerender } = renderHook(() => useFleetData());

    act(() => {
      result.current.refetch();
    });
    await waitFor(() => expect(fetchMock).toHaveBeenCalled());

    auth.current = {
      ready: true,
      authenticated: true,
      user: { id: "account-b" },
      login: vi.fn(),
      getAccessToken: vi.fn().mockResolvedValue("token-b"),
    };
    rerender();
    await act(async () => {
      rejectProviders(new Error("account-a request failed"));
      await Promise.resolve();
    });

    await waitFor(() => {
      expect(result.current.error).toBeNull();
      expect(result.current.pollFailed).toBe(false);
    });
  });
});
