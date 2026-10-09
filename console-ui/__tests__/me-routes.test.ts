import { describe, it, expect } from "vitest";
import {
  DEFAULT_COORD,
  makeRequest,
  stubUpstreamFetch,
  upstreamError,
  upstreamOk,
} from "./helpers/route-harness";

// Proxy tests for the /api/me/* route handlers: each imports the exported
// handler directly and drives it with a synthetic NextRequest.

const upstream = stubUpstreamFetch();

describe("GET /api/me/providers", () => {
  it("proxies auth to coordinator /v1/me/providers", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ providers: [], latest_provider_version: "0.3.10" })
    );

    const { GET } = await import("@/app/api/me/providers/route");
    const req = makeRequest("/api/me/providers", {
      headers: {
        authorization: "Bearer privy-token-123",
        "x-coordinator-url": "https://attacker.example.com",
      },
    });
    const res = await GET(req);

    expect(res.status).toBe(200);
    const [upstreamUrl, upstreamOpts] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/me/providers`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer privy-token-123");
  });

  it("rejects missing auth", async () => {
    const { GET } = await import("@/app/api/me/providers/route");
    const req = makeRequest("/api/me/providers");
    const res = await GET(req);

    expect(res.status).toBe(401);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});

describe("GET /api/me/provider-models", () => {
  // The proxy is a thin passthrough: eligibility filtering and alias
  // translation live coordinator-side in /v1/me/self-route-models (tested in
  // Go), so the picker's ids always match what self-route clients will see.
  it("proxies the coordinator's alias-aware self-route model view", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ models: ["gemma-4-26b", "local/off-catalog"] })
    );

    const { GET } = await import("@/app/api/me/provider-models/route");
    const req = makeRequest("/api/me/provider-models", {
      headers: { authorization: "Bearer privy-token-123" },
    });
    const res = await GET(req);

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({
      models: ["gemma-4-26b", "local/off-catalog"],
    });
    const [upstreamUrl, upstreamOpts] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/me/self-route-models`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer privy-token-123");
  });

  it("sanitizes a malformed upstream payload to an empty list", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ models: [42, null, "", "ok/model"] })
    );

    const { GET } = await import("@/app/api/me/provider-models/route");
    const res = await GET(
      makeRequest("/api/me/provider-models", {
        headers: { authorization: "Bearer privy-token-123" },
      })
    );

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ models: ["ok/model"] });
  });

  it("propagates upstream errors", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamError(503, "unavailable"));

    const { GET } = await import("@/app/api/me/provider-models/route");
    const res = await GET(
      makeRequest("/api/me/provider-models", {
        headers: { authorization: "Bearer privy-token-123" },
      })
    );

    expect(res.status).toBe(503);
  });

  it("rejects missing auth", async () => {
    const { GET } = await import("@/app/api/me/provider-models/route");
    const res = await GET(makeRequest("/api/me/provider-models"));

    expect(res.status).toBe(401);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});

describe("GET /api/me/summary", () => {
  it("proxies auth to coordinator /v1/me/summary", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ account_id: "acct-1", counts: { total: 0 } })
    );

    const { GET } = await import("@/app/api/me/summary/route");
    const req = makeRequest("/api/me/summary", {
      headers: {
        authorization: "Bearer privy-token-123",
        "x-coordinator-url": "https://attacker.example.com",
      },
    });
    const res = await GET(req);

    expect(res.status).toBe(200);
    const [upstreamUrl, upstreamOpts] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/me/summary`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer privy-token-123");
  });
});
