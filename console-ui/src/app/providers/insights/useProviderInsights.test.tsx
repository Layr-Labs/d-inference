import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { useProviderInsights } from "./useProviderInsights";
import { makeInsights } from "./testFixtures";
const auth = vi.hoisted(() => ({ ready: true, authenticated: true, user: { id: "one" }, getAccessToken: vi.fn(async () => "token") }));
vi.mock("@/hooks/useAuth", () => ({ useAuth: () => auth }));
beforeEach(() => { auth.authenticated = true; auth.user = { id: "one" }; });
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
const response = (value: unknown) => ({ ok: true, json: async () => value }) as Response;

it("clears on account switches and ignores a late response from the old account", async () => {
  let complete!: (response: Response) => void;
  const pending = new Promise<Response>(resolve => { complete = resolve; });
  const fetchMock = vi.fn().mockReturnValueOnce(pending).mockResolvedValueOnce(response(makeInsights({ lifetime: { count: 2, total_micro_usd: 2, prompt_tokens: 2, completion_tokens: 2 } })));
  vi.stubGlobal("fetch", fetchMock);
  const { result, rerender } = renderHook(() => useProviderInsights());
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
  const oldSignal = fetchMock.mock.calls[0][1].signal;
  auth.user = { id: "two" }; rerender();
  expect(oldSignal.aborted).toBe(true);
  expect(result.current.data).toBeNull();
  await waitFor(() => expect(result.current.data?.lifetime.count).toBe(2));
  await act(async () => complete(response(makeInsights())));
  expect(result.current.data?.lifetime.count).toBe(2);
  auth.authenticated = false; rerender();
  expect(result.current.data).toBeNull();
});

it("retains and marks the last successful snapshot on failure and clears it for a new window", async () => {
  vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(response(makeInsights())).mockResolvedValue({ ok: false, status: 503 }));
  const { result, rerender } = renderHook(({ window }: { window: "7d" | "30d" }) => useProviderInsights(window), { initialProps: { window: "7d" } });
  await waitFor(() => expect(result.current.data).not.toBeNull());
  await act(() => result.current.refresh());
  expect(result.current.error).toBe("Could not refresh your insights.");
  expect(result.current.data).not.toBeNull();
  rerender({ window: "30d" });
  expect(result.current.data).toBeNull();
  await waitFor(() => expect(result.current.error).toBeTruthy());
});
