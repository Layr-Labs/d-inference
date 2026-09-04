import { StrictMode } from "react";
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useNetworkStats } from "./useNetworkStats";

const SNAPSHOT_AT = "2026-09-04T12:00:00.000Z";
const FETCHED_AT = "2026-09-04T12:00:05.000Z";
const stats = { active_providers: 12, providers: [], models: [], time_series: [] };
const catalog = { data: [{ id: "test-model", status: "active" }] };
const capacity = { models: [{ id: "test-model", ready: true, can_accept: true }] };
const totals = { tokens: 4_000, jobs: 30, window: "24h", updated_at: SNAPSHOT_AT };
const upstreamFetch = vi.fn<typeof fetch>();

function responseFor(input: RequestInfo | URL) {
  const url = String(input);
  if (url.startsWith("/api/stats")) {
    return Response.json(stats, { headers: { "X-Stats-Snapshot-At": SNAPSHOT_AT, "X-Stats-Fetched-At": FETCHED_AT } });
  }
  if (url === "/api/models") return Response.json(catalog);
  if (url === "/api/models/capacity") return Response.json(capacity);
  if (url === "/api/network/totals?window=24h") return Response.json(totals);
  throw new Error(`Unexpected endpoint ${url}`);
}

function requestsTo(path: string) {
  return upstreamFetch.mock.calls.filter(([input]) => String(input) === path);
}

function pendingResponse() {
  let complete!: (value: Response) => void;
  const promise = new Promise<Response>((resolve) => { complete = resolve; });
  return { promise, resolve: complete };
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date(SNAPSHOT_AT));
  Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true });
  upstreamFetch.mockReset();
  upstreamFetch.mockImplementation(async (input) => responseFor(input));
  vi.stubGlobal("fetch", upstreamFetch);
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("useNetworkStats", () => {
  it("loads immediately in Strict Mode after the abandoned mount is cancelled", async () => {
    const { result } = renderHook(() => useNetworkStats(), { wrapper: StrictMode });
    await act(async () => {});

    expect(result.current.stats).toEqual(stats);
    expect(result.current.snapshotAt).toBe(SNAPSHOT_AT);
    expect(result.current.fetchedAt).toBe(FETCHED_AT);
    expect(result.current.refreshing).toBe(false);
    expect(result.current.error).toBeNull();
    expect(requestsTo("/api/stats")).toHaveLength(2);
    const abandonedSignal = requestsTo("/api/stats")[0][1]?.signal;
    expect(abandonedSignal?.aborted).toBe(true);
    expect(requestsTo("/api/stats")[1][1]?.signal?.aborted).toBe(false);
  });

  it("polls at 30-second intervals and coalesces manual refreshes while a request is pending", async () => {
    const { result } = renderHook(() => useNetworkStats());
    await act(async () => {});
    await act(async () => { vi.advanceTimersByTime(29_999); });
    expect(requestsTo("/api/stats")).toHaveLength(1);

    const pending = pendingResponse();
    upstreamFetch.mockImplementation((input) => String(input) === "/api/stats" ? pending.promise : Promise.resolve(responseFor(input)));
    await act(async () => { vi.advanceTimersByTime(1); });
    expect(requestsTo("/api/stats")).toHaveLength(2);
    expect(result.current.refreshing).toBe(true);
    await act(async () => {
      result.current.refresh();
      result.current.refresh();
    });
    expect(requestsTo("/api/stats")).toHaveLength(2);

    await act(async () => { pending.resolve(responseFor("/api/stats")); });
    expect(result.current.refreshing).toBe(false);
    upstreamFetch.mockImplementation(async (input) => responseFor(input));
    await act(async () => { vi.advanceTimersByTime(30_000); });
    expect(requestsTo("/api/stats")).toHaveLength(3);
  });

  it("does not let an abandoned mount clear the active mount's in-flight request", async () => {
    const abandoned = pendingResponse();
    const active = pendingResponse();
    let primaryCalls = 0;
    upstreamFetch.mockImplementation((input) => {
      if (String(input) !== "/api/stats") return Promise.resolve(responseFor(input));
      primaryCalls += 1;
      return primaryCalls === 1 ? abandoned.promise : active.promise;
    });
    const { result } = renderHook(() => useNetworkStats(), { wrapper: StrictMode });
    await act(async () => { abandoned.resolve(responseFor("/api/stats")); });
    expect(result.current.stats).toBeNull();
    expect(result.current.refreshing).toBe(true);

    await act(async () => { result.current.refresh(); });
    expect(requestsTo("/api/stats")).toHaveLength(2);
    await act(async () => { active.resolve(responseFor("/api/stats")); });
    expect(result.current.stats).toEqual(stats);
    expect(result.current.refreshing).toBe(false);
  });

  it("shows the primary snapshot while auxiliary requests are still pending", async () => {
    const auxiliary = pendingResponse();
    upstreamFetch.mockImplementation((input) => String(input) === "/api/stats" ? Promise.resolve(responseFor(input)) : auxiliary.promise);
    const { result } = renderHook(() => useNetworkStats());
    await act(async () => {});

    expect(result.current.stats).toEqual(stats);
    expect(result.current.snapshotAt).toBe(SNAPSHOT_AT);
    expect(result.current.refreshing).toBe(false);
    expect(result.current.catalogData).toBeNull();
    expect(result.current.capacityModels).toBeNull();
    expect(result.current.totals24h).toBeNull();
    await act(async () => { result.current.refresh(); });
    expect(requestsTo("/api/models")).toHaveLength(1);
    await act(async () => { auxiliary.resolve(Response.json({})); });
  });

  it("retains the original snapshot and its date when a refresh fails, then recovers", async () => {
    const { result } = renderHook(() => useNetworkStats());
    await act(async () => {});
    upstreamFetch.mockImplementation(async (input) => String(input) === "/api/stats" ? new Response(null, { status: 503 }) : responseFor(input));
    await act(async () => { vi.advanceTimersByTime(30_000); });

    expect(result.current.stats).toEqual(stats);
    expect(result.current.snapshotAt).toBe(SNAPSHOT_AT);
    expect(result.current.fetchedAt).toBe(FETCHED_AT);
    expect(result.current.error).toBe("The latest snapshot couldn’t be loaded.");
    expect(result.current.refreshing).toBe(false);

    const nextSnapshotAt = "2026-09-04T12:00:30.000Z";
    upstreamFetch.mockImplementation(async (input) => String(input) === "/api/stats"
      ? Response.json({ ...stats, active_providers: 14 }, { headers: { "X-Stats-Snapshot-At": nextSnapshotAt } })
      : responseFor(input));
    await act(async () => { result.current.refresh(); });
    expect(result.current.stats?.active_providers).toBe(14);
    expect(result.current.snapshotAt).toBe(nextSnapshotAt);
    expect(result.current.error).toBeNull();
  });

  it("clears failed auxiliary data to unknown instead of retaining a previous value", async () => {
    const { result } = renderHook(() => useNetworkStats());
    await act(async () => {});
    expect(result.current.catalogData?.models[0]?.id).toBe("test-model");
    expect(result.current.capacityModels?.[0]?.ready).toBe(true);
    expect(result.current.totals24h).toEqual(totals);

    upstreamFetch.mockImplementation(async (input) => String(input) === "/api/stats" ? responseFor(input) : new Response(null, { status: 503 }));
    await act(async () => { result.current.refresh(); });
    expect(result.current.stats).toEqual(stats);
    expect(result.current.catalogData).toBeNull();
    expect(result.current.capacityModels).toBeNull();
    expect(result.current.totals24h).toBeNull();
    expect(result.current.secondaryError).toBe(true);
    expect(result.current.error).toBeNull();
  });

  it("rejects malformed primary data and does not invent a timestamp when the header is absent", async () => {
    upstreamFetch.mockImplementation(async (input) => String(input) === "/api/stats" ? Response.json(stats) : responseFor(input));
    const { result } = renderHook(() => useNetworkStats());
    await act(async () => {});
    expect(result.current.stats).toEqual(stats);
    expect(result.current.snapshotAt).toBeNull();

    upstreamFetch.mockImplementation(async (input) => String(input) === "/api/stats" ? Response.json({ error: "bad snapshot" }) : responseFor(input));
    await act(async () => { result.current.refresh(); });
    expect(result.current.stats).toEqual(stats);
    expect(result.current.error).not.toBeNull();
    expect(result.current.snapshotAt).toBeNull();
  });

  it("identifies mock snapshots from the server header and clears the flag on a real snapshot", async () => {
    upstreamFetch.mockImplementation(async (input) => String(input) === "/api/stats"
      ? Response.json(stats, { headers: { "X-Stats-Cache": "MOCK" } })
      : responseFor(input));
    const { result } = renderHook(() => useNetworkStats());
    await act(async () => {});
    expect(result.current.isMock).toBe(true);
    expect(result.current.snapshotAt).toBeNull();
    expect(result.current.fetchedAt).toBeNull();

    upstreamFetch.mockImplementation(async (input) => responseFor(input));
    await act(async () => { result.current.refresh(); });
    expect(result.current.isMock).toBe(false);
    expect(result.current.snapshotAt).toBe(SNAPSHOT_AT);
  });

  it("keeps fetch time distinct when the coordinator has not published a source timestamp", async () => {
    upstreamFetch.mockImplementation(async (input) => String(input) === "/api/stats"
      ? Response.json(stats, { headers: { "X-Stats-Fetched-At": FETCHED_AT } })
      : responseFor(input));
    const { result } = renderHook(() => useNetworkStats());
    await act(async () => {});
    expect(result.current.stats).toEqual(stats);
    expect(result.current.fetchedAt).toBe(FETCHED_AT);
    expect(result.current.snapshotAt).toBeNull();
  });
});
