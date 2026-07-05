import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { NextRequest } from "next/server";

// Tests for the proxy routes added in the direct-fetch → proxy migration.

let upstreamFetch: ReturnType<typeof vi.fn>;
const DEFAULT_COORD = "https://api.darkbloom.dev";

beforeEach(() => {
  upstreamFetch = vi.fn();
  vi.stubGlobal("fetch", upstreamFetch);
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.resetModules();
});

function req(url: string, init?: { method?: string; headers?: Record<string, string>; body?: string }): NextRequest {
  return new NextRequest(new URL(url, "http://localhost:3000"), {
    method: init?.method ?? "GET",
    headers: init?.headers ?? {},
    ...(init?.body ? { body: init.body } : {}),
  });
}

function ok(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
}

describe("GET /api/me/earnings", () => {
  it("proxies auth to /v1/provider/account-earnings with the limit", async () => {
    upstreamFetch.mockResolvedValueOnce(ok({ earnings: [], total_usd: "0" }));
    const { GET } = await import("@/app/api/me/earnings/route");
    const res = await GET(req("/api/me/earnings?limit=50", { headers: { authorization: "Bearer tok" } }));
    expect(res.status).toBe(200);
    const [url, opts] = upstreamFetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/provider/account-earnings?limit=50`);
    expect(opts.headers.Authorization).toBe("Bearer tok");
  });

  it("rejects missing auth with 401", async () => {
    const { GET } = await import("@/app/api/me/earnings/route");
    const res = await GET(req("/api/me/earnings"));
    expect(res.status).toBe(401);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });
});

describe("POST /api/device/approve", () => {
  it("forwards the user_code + auth to /v1/device/approve", async () => {
    upstreamFetch.mockResolvedValueOnce(ok({ status: "approved" }));
    const { POST } = await import("@/app/api/device/approve/route");
    const res = await POST(
      req("/api/device/approve", {
        method: "POST",
        headers: { authorization: "Bearer tok", "content-type": "application/json" },
        body: JSON.stringify({ user_code: "ABCD-1234" }),
      }),
    );
    expect(res.status).toBe(200);
    const [url, opts] = upstreamFetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/device/approve`);
    expect(opts.method).toBe("POST");
    expect(JSON.parse(opts.body)).toEqual({ user_code: "ABCD-1234" });
  });

  it("rejects missing auth with 401", async () => {
    const { POST } = await import("@/app/api/device/approve/route");
    const res = await POST(req("/api/device/approve", { method: "POST", body: "{}" }));
    expect(res.status).toBe(401);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });
});

describe("GET /api/attestation?summary=1", () => {
  it("returns a slim count + last_verified instead of the full blob", async () => {
    upstreamFetch.mockResolvedValueOnce(
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
    upstreamFetch.mockResolvedValueOnce(ok({ providers: [{ trust_level: "hardware" }] }));
    const { GET } = await import("@/app/api/attestation/route");
    const res = await GET(req("/api/attestation"));
    const data = await res.json();
    expect(data.providers).toHaveLength(1);
  });
});
