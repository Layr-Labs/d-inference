import { afterEach, describe, it, expect, vi } from "vitest";
import { EARNINGS_MARKET_TIMEOUT_MS } from "@/lib/api/earnings-market";
import {
  DEFAULT_COORD,
  makeRequest as req,
  stubUpstreamFetch,
  upstreamOk as ok,
} from "./helpers/route-harness";

// Tests for the proxy routes added in the direct-fetch → proxy migration.

const upstream = stubUpstreamFetch();
const CACHE_CONTROL = "Cache-Control";

afterEach(() => {
  vi.useRealTimers();
});

describe("GET /api/earnings/market", () => {
  it("proxies the public calculator snapshot without credentials", async () => {
    upstream.fetch.mockResolvedValueOnce(ok({ window_days: 30, models: [] }));
    const { GET } = await import("@/app/api/earnings/market/route");
    const res = await GET();

    expect(res.status).toBe(200);
    expect(upstream.fetch).toHaveBeenCalledWith(
      `${DEFAULT_COORD}/v1/earnings/market`,
      expect.objectContaining({
        cache: "no-store",
        signal: expect.any(AbortSignal),
      }),
    );
    expect(res.headers.get(CACHE_CONTROL)).toContain("s-maxage=60");
  });

  it("never CDN-caches a transient coordinator failure", async () => {
    upstream.fetch.mockResolvedValueOnce(
      new Response(JSON.stringify({ error: { message: "temporarily unavailable" } }), {
        status: 503,
        headers: { "Content-Type": "application/json" },
      }),
    );
    const { GET } = await import("@/app/api/earnings/market/route");
    const res = await GET();

    expect(res.status).toBe(503);
    expect(res.headers.get(CACHE_CONTROL)).toBe("no-store");
  });

  it("terminates a stalled coordinator request as unavailable", async () => {
    vi.useFakeTimers();
    upstream.fetch.mockImplementationOnce((_url: string, init?: RequestInit) => {
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(new DOMException("The operation was aborted", "AbortError"));
        });
      });
    });
    const { GET } = await import("@/app/api/earnings/market/route");
    const pending = GET();

    await vi.advanceTimersByTimeAsync(EARNINGS_MARKET_TIMEOUT_MS);
    const res = await pending;

    expect(res.status).toBe(503);
    expect(res.headers.get(CACHE_CONTROL)).toBe("no-store");
  });
});

describe("GET /api/me/earnings", () => {
  it("proxies auth to /v1/provider/account-earnings with the limit", async () => {
    upstream.fetch.mockResolvedValueOnce(ok({ earnings: [], total_usd: "0" }));
    const { GET } = await import("@/app/api/me/earnings/route");
    const res = await GET(req("/api/me/earnings?limit=50", { headers: { authorization: "Bearer tok" } }));
    expect(res.status).toBe(200);
    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/provider/account-earnings?limit=50`);
    expect(opts.headers.Authorization).toBe("Bearer tok");
  });

  it("rejects missing auth with 401", async () => {
    const { GET } = await import("@/app/api/me/earnings/route");
    const res = await GET(req("/api/me/earnings"));
    expect(res.status).toBe(401);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});

describe("POST /api/device/approve", () => {
  it("forwards the user_code + auth to /v1/device/approve", async () => {
    upstream.fetch.mockResolvedValueOnce(ok({ status: "approved" }));
    const { POST } = await import("@/app/api/device/approve/route");
    const res = await POST(
      req("/api/device/approve", {
        method: "POST",
        headers: { authorization: "Bearer tok", "content-type": "application/json" },
        body: JSON.stringify({ user_code: "ABCD-1234" }),
      }),
    );
    expect(res.status).toBe(200);
    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/device/approve`);
    expect(opts.method).toBe("POST");
    expect(JSON.parse(opts.body)).toEqual({ user_code: "ABCD-1234" });
  });

  it("rejects missing auth with 401", async () => {
    const { POST } = await import("@/app/api/device/approve/route");
    const res = await POST(req("/api/device/approve", { method: "POST", body: "{}" }));
    expect(res.status).toBe(401);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});

describe("GET /api/attestation?summary=1", () => {
  it("returns a slim count + last_verified instead of the full blob", async () => {
    upstream.fetch.mockResolvedValueOnce(
      ok({
        providers: [
          { trust_level: "hardware", last_challenge_time: "2026-06-22T10:00:00Z" },
          { trust_level: "hardware", last_challenge_time: "2026-06-22T11:00:00Z" },
          { trust_level: "none", last_challenge_time: "2026-06-22T12:00:00Z" },
          // huge cert chains that should NOT reach the client
          { trust_level: "hardware", mda_cert_chain_b64: ["x".repeat(1000)] },
        ],
      }),
    );
    const { GET } = await import("@/app/api/attestation/route");
    const res = await GET(req("/api/attestation?summary=1"));
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data).toEqual({ count: 3, last_verified: "2026-06-22T11:00:00.000Z" });
    expect(JSON.stringify(data)).not.toContain("mda_cert_chain");
  });

  it("returns the full blob without summary", async () => {
    upstream.fetch.mockResolvedValueOnce(ok({ providers: [{ trust_level: "hardware" }] }));
    const { GET } = await import("@/app/api/attestation/route");
    const res = await GET(req("/api/attestation"));
    const data = await res.json();
    expect(data.providers).toHaveLength(1);
  });
});
