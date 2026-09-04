import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";

const START = new Date("2026-09-04T12:00:00Z");
const COORDINATOR = "https://coordinator.example";
const upstreamFetch = vi.fn<typeof fetch>();

const request = (query = "") => new NextRequest(`http://localhost/api/stats${query}`);
const stats = (activeProviders: number) => ({ active_providers: activeProviders, providers: [] });

beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  vi.setSystemTime(START);
  vi.stubEnv("NEXT_PUBLIC_COORDINATOR_URL", COORDINATOR);
  upstreamFetch.mockReset();
  vi.stubGlobal("fetch", upstreamFetch);
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("GET /api/stats snapshot caching", () => {
  it("preserves the coordinator's source timestamp and bounds all cache layers to its remaining lifetime", async () => {
    const sourceTime = "2026-09-04T11:59:40.000Z";
    upstreamFetch.mockResolvedValueOnce(Response.json({ ...stats(5), snapshot_at: sourceTime }));
    const { GET } = await import("@/app/api/stats/route");
    const initial = await GET(request());
    expect(initial.headers.get("X-Stats-Snapshot-At")).toBe(sourceTime);
    expect(initial.headers.get("X-Stats-Fetched-At")).toBe(START.toISOString());
    expect(initial.headers.get("X-Stats-Expires-At")).toBe("2026-09-04T12:00:10.000Z");
    expect(initial.headers.get("Cache-Control")).toBe("public, max-age=0, s-maxage=10, must-revalidate");

    vi.setSystemTime(START.getTime() + 9_999);
    const hit = await GET(request());
    expect(hit.headers.get("X-Stats-Cache")).toBe("HIT");
    expect(hit.headers.get("X-Stats-Snapshot-At")).toBe(sourceTime);
    expect(hit.headers.get("X-Stats-Fetched-At")).toBe(START.toISOString());

    vi.setSystemTime(START.getTime() + 10_000);
    const refreshedSource = new Date().toISOString();
    upstreamFetch.mockResolvedValueOnce(Response.json({ ...stats(6), snapshot_at: refreshedSource }));
    const refreshed = await GET(request());
    expect(refreshed.headers.get("X-Stats-Cache")).toBe("MISS");
    expect(refreshed.headers.get("X-Stats-Snapshot-At")).toBe(refreshedSource);
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
  });

  it.each([undefined, "not a timestamp", "2026", 42])("does not invent source time when snapshot_at is %s", async (snapshotAt) => {
    upstreamFetch.mockResolvedValueOnce(Response.json({ ...stats(5), snapshot_at: snapshotAt }));
    const { GET } = await import("@/app/api/stats/route");
    const response = await GET(request());
    expect(response.headers.has("X-Stats-Snapshot-At")).toBe(false);
    expect(response.headers.get("X-Stats-Fetched-At")).toBe(START.toISOString());
    expect(response.headers.get("X-Stats-Expires-At")).toBe("2026-09-04T12:00:30.000Z");
  });

  it("does not retain an already expired source snapshot in the proxy or edge cache", async () => {
    const sourceTime = "2026-09-04T11:59:00.000Z";
    upstreamFetch.mockResolvedValueOnce(Response.json({ ...stats(5), snapshot_at: sourceTime }));
    upstreamFetch.mockResolvedValueOnce(Response.json({ ...stats(6), snapshot_at: START.toISOString() }));
    const { GET } = await import("@/app/api/stats/route");
    const expired = await GET(request());
    expect(expired.headers.get("X-Stats-Snapshot-At")).toBe(sourceTime);
    expect(expired.headers.get("Cache-Control")).toBe("public, max-age=0, s-maxage=0, must-revalidate");
    const refreshed = await GET(request());
    expect(refreshed.headers.get("X-Stats-Cache")).toBe("MISS");
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
  });

  it("reuses a successful snapshot for 30 seconds and refreshes exactly at expiry", async () => {
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(12)));
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(15)));
    const { GET } = await import("@/app/api/stats/route");

    const initial = await GET(request());
    expect(await initial.json()).toEqual(stats(12));
    expect(initial.headers.get("X-Stats-Cache")).toBe("MISS");
    expect(initial.headers.get("X-Stats-Fetched-At")).toBe(START.toISOString());
    expect(initial.headers.get("X-Stats-Expires-At")).toBe("2026-09-04T12:00:30.000Z");
    expect(initial.headers.get("Cache-Control")).toBe("public, max-age=0, s-maxage=30, must-revalidate");

    vi.setSystemTime(START.getTime() + 29_999);
    const cached = await GET(request());
    expect(await cached.json()).toEqual(stats(12));
    expect(cached.headers.get("X-Stats-Cache")).toBe("HIT");
    expect(cached.headers.get("X-Stats-Fetched-At")).toBe(START.toISOString());
    expect(cached.headers.get("X-Stats-Expires-At")).toBe("2026-09-04T12:00:30.000Z");
    expect(cached.headers.get("Cache-Control")).toBe("public, max-age=0, s-maxage=0, must-revalidate");
    expect(upstreamFetch).toHaveBeenCalledTimes(1);

    vi.setSystemTime(START.getTime() + 30_000);
    const refreshed = await GET(request());
    expect(await refreshed.json()).toEqual(stats(15));
    expect(refreshed.headers.get("X-Stats-Cache")).toBe("MISS");
    expect(refreshed.headers.get("X-Stats-Fetched-At")).toBe("2026-09-04T12:00:30.000Z");
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
    expect(upstreamFetch).toHaveBeenLastCalledWith(`${COORDINATOR}/v1/stats`, { cache: "no-store", signal: expect.any(AbortSignal) });
  });

  it("coalesces concurrent requests and includes upstream latency in snapshot age", async () => {
    let complete!: (response: Response) => void;
    upstreamFetch.mockReturnValueOnce(new Promise((resolve) => { complete = resolve; }));
    const { GET } = await import("@/app/api/stats/route");

    const first = GET(request());
    const second = GET(request());
    const third = GET(request());
    expect(upstreamFetch).toHaveBeenCalledTimes(1);

    vi.setSystemTime(START.getTime() + 5_000);
    complete(Response.json(stats(8)));
    const responses = await Promise.all([first, second, third]);
    for (const response of responses) {
      expect(await response.json()).toEqual(stats(8));
      expect(response.headers.get("X-Stats-Fetched-At")).toBe(START.toISOString());
      expect(response.headers.get("Cache-Control")).toBe("public, max-age=0, s-maxage=25, must-revalidate");
    }
    expect(upstreamFetch).toHaveBeenCalledTimes(1);
  });

  it("coalesces an expired snapshot refresh without serving the expired data", async () => {
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(8)));
    const { GET } = await import("@/app/api/stats/route");
    await GET(request());
    vi.setSystemTime(START.getTime() + 30_000);

    let complete!: (response: Response) => void;
    upstreamFetch.mockReturnValueOnce(new Promise((resolve) => { complete = resolve; }));
    const refresh = GET(request());
    const concurrent = GET(request());
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
    complete(Response.json(stats(9)));

    const responses = await Promise.all([refresh, concurrent]);
    for (const response of responses) expect(await response.json()).toEqual(stats(9));
  });

  it("never extends freshness if the clock moves past the cache window during an upstream request", async () => {
    let complete!: (response: Response) => void;
    upstreamFetch.mockReturnValueOnce(new Promise((resolve) => { complete = resolve; }));
    const { GET } = await import("@/app/api/stats/route");
    const slowRequest = GET(request());
    vi.setSystemTime(START.getTime() + 31_000);
    complete(Response.json(stats(8)));

    const slowResponse = await slowRequest;
    expect(slowResponse.headers.get("X-Stats-Fetched-At")).toBe(START.toISOString());
    expect(slowResponse.headers.get("X-Stats-Expires-At")).toBe("2026-09-04T12:00:30.000Z");
    expect(slowResponse.headers.get("Cache-Control")).toBe("public, max-age=0, s-maxage=0, must-revalidate");

    upstreamFetch.mockResolvedValueOnce(Response.json(stats(9)));
    const nextResponse = await GET(request());
    expect(await nextResponse.json()).toEqual(stats(9));
    expect(nextResponse.headers.get("X-Stats-Cache")).toBe("MISS");
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
  });

  it("keeps snapshots isolated by the configured coordinator", async () => {
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(2)));
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(20)));
    const { GET } = await import("@/app/api/stats/route");

    expect(await (await GET(request())).json()).toEqual(stats(2));
    vi.stubEnv("NEXT_PUBLIC_COORDINATOR_URL", "https://another-coordinator.example");
    expect(await (await GET(request())).json()).toEqual(stats(20));
    vi.stubEnv("NEXT_PUBLIC_COORDINATOR_URL", COORDINATOR);
    expect(await (await GET(request())).json()).toEqual(stats(2));
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
  });

  it("does not cache upstream failures and allows the next request to retry", async () => {
    upstreamFetch.mockResolvedValueOnce(new Response("unavailable", { status: 503 }));
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(7)));
    const { GET } = await import("@/app/api/stats/route");

    const failed = await GET(request());
    expect(failed.status).toBe(503);
    expect(await failed.json()).toEqual({ error: "Upstream 503" });
    expect(failed.headers.get("Cache-Control")).toBe("no-store");
    expect(failed.headers.has("X-Stats-Fetched-At")).toBe(false);
    expect(await (await GET(request())).json()).toEqual(stats(7));
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
  });

  it("clears a failed in-flight request for all waiters and retries", async () => {
    let fail!: (error: Error) => void;
    upstreamFetch.mockReturnValueOnce(new Promise((_resolve, reject) => { fail = reject; }));
    const { GET } = await import("@/app/api/stats/route");
    const first = GET(request());
    const second = GET(request());
    fail(new Error("Network unavailable"));

    const responses = await Promise.all([first, second]);
    for (const response of responses) {
      expect(response.status).toBe(502);
      expect(response.headers.get("Cache-Control")).toBe("no-store");
    }
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(11)));
    expect(await (await GET(request())).json()).toEqual(stats(11));
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
  });

  it("aborts a stalled upstream at 20 seconds, releases all waiters, and allows recovery", async () => {
    upstreamFetch.mockImplementationOnce((_input, init) => new Promise((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
    }));
    const { GET } = await import("@/app/api/stats/route");
    const first = GET(request());
    const second = GET(request());
    expect(upstreamFetch).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(19_999);
    expect(upstreamFetch.mock.calls[0][1]?.signal?.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    const responses = await Promise.all([first, second]);
    for (const response of responses) {
      expect(response.status).toBe(504);
      expect(response.headers.get("Cache-Control")).toBe("no-store");
      expect(response.headers.has("X-Stats-Fetched-At")).toBe(false);
    }

    upstreamFetch.mockResolvedValueOnce(Response.json(stats(13)));
    const recovered = await GET(request());
    expect(await recovered.json()).toEqual(stats(13));
    expect(recovered.headers.get("X-Stats-Fetched-At")).toBe("2026-09-04T12:00:20.000Z");
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("does not cache malformed JSON or return an expired snapshot after a failure", async () => {
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(4)));
    upstreamFetch.mockResolvedValueOnce(new Response("not json", { status: 200 }));
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(5)));
    const { GET } = await import("@/app/api/stats/route");
    await GET(request());
    vi.setSystemTime(START.getTime() + 30_000);

    const failed = await GET(request());
    expect(failed.status).toBe(502);
    expect(failed.headers.has("X-Stats-Fetched-At")).toBe(false);
    expect(await (await GET(request())).json()).toEqual(stats(5));
    expect(upstreamFetch).toHaveBeenCalledTimes(3);
  });

  it("keeps mock geography out of the real snapshot and out of browser or edge caches", async () => {
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(3)));
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(30)));
    upstreamFetch.mockResolvedValueOnce(Response.json(stats(31)));
    const { GET } = await import("@/app/api/stats/route");
    await GET(request());

    const mocked = await GET(request("?mock=geo"));
    expect(mocked.headers.get("Cache-Control")).toBe("no-store");
    expect(mocked.headers.get("X-Stats-Cache")).toBe("MOCK");
    expect(mocked.headers.has("X-Stats-Fetched-At")).toBe(false);
    expect(await mocked.json()).toMatchObject({ active_providers: 30 });

    const secondMock = await GET(request("?mock=geo"));
    expect(await secondMock.json()).toMatchObject({ active_providers: 31 });
    expect(await (await GET(request())).json()).toEqual(stats(3));
    expect(upstreamFetch).toHaveBeenCalledTimes(3);
  });
});
