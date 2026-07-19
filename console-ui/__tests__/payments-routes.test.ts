import { describe, it, expect } from "vitest";
import {
  DEFAULT_COORD,
  makeRequest,
  stubUpstreamFetch,
  upstreamError,
  upstreamOk,
} from "./helpers/route-harness";

// Proxy tests for the payments + invite route handlers.

const upstream = stubUpstreamFetch();

describe("GET /api/payments/balance", () => {
  it("proxies to coordinator /v1/payments/balance", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ balance_micro_usd: 1000, balance_usd: 0.001 })
    );

    const { GET } = await import("@/app/api/payments/balance/route");
    const req = makeRequest("/api/payments/balance", {
      headers: {
        "x-api-key": "key123",
      },
    });
    const res = await GET(req);
    const data = await res.json();

    expect(upstream.fetch).toHaveBeenCalledOnce();
    const [upstreamUrl, upstreamOpts] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/payments/balance`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer key123");

    expect(res.status).toBe(200);
    expect(data.balance_usd).toBe(0.001);
  });

  it("ignores x-coordinator-url header (SSRF prevention)", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ balance_micro_usd: 0, balance_usd: 0 })
    );

    const { GET } = await import("@/app/api/payments/balance/route");
    const req = makeRequest("/api/payments/balance", {
      headers: {
        "x-coordinator-url": "https://attacker.example.com",
        "x-api-key": "key123",
      },
    });
    await GET(req);

    const [upstreamUrl] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/payments/balance`);
  });

  it("returns upstream status on error", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamError(401));

    const { GET } = await import("@/app/api/payments/balance/route");
    const req = makeRequest("/api/payments/balance");
    const res = await GET(req);

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toContain("401");
  });

  it("uses default coordinator URL when header missing", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ balance_micro_usd: 0, balance_usd: 0 })
    );

    const { GET } = await import("@/app/api/payments/balance/route");
    const req = makeRequest("/api/payments/balance");
    await GET(req);

    const [upstreamUrl] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toContain("/v1/payments/balance");
  });
});

describe("POST /api/payments/stripe/checkout", () => {
  it("forwards body and auth to coordinator /v1/billing/stripe/create-session", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ url: "https://checkout.stripe.com/session/123", session_id: "cs_123" })
    );

    const { POST } = await import("@/app/api/payments/stripe/checkout/route");
    const req = makeRequest("/api/payments/stripe/checkout", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        authorization: "Bearer privy-token-123",
      },
      body: JSON.stringify({ amount_usd: "10" }),
    });
    const res = await POST(req);

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.url).toBe("https://checkout.stripe.com/session/123");

    const [upstreamUrl, upstreamOpts] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/billing/stripe/create-session`);
    expect(upstreamOpts.method).toBe("POST");
    expect(upstreamOpts.headers["Content-Type"]).toBe("application/json");
    expect(upstreamOpts.headers.Authorization).toBe("Bearer privy-token-123");
    expect(JSON.parse(upstreamOpts.body)).toEqual({ amount_usd: "10" });
  });

  it("returns error on upstream failure", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamError(400, "bad request"));

    const { POST } = await import("@/app/api/payments/stripe/checkout/route");
    const req = makeRequest("/api/payments/stripe/checkout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ amount_usd: "-1" }),
    });
    const res = await POST(req);

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe("bad request");
  });
});

describe("PUT /api/payments/stripe/auto-withdraw", () => {
  it("forwards explicit authorization and Privy auth", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({
        auto_withdraw_enabled: true,
        auto_withdraw_next_at: "2026-07-20T09:00:00Z",
      })
    );
    const { PUT } = await import("@/app/api/payments/stripe/auto-withdraw/route");
    const req = makeRequest("/api/payments/stripe/auto-withdraw", {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        authorization: "Bearer privy-token-123",
      },
      body: JSON.stringify({ enabled: true }),
    });

    const res = await PUT(req);

    expect(res.status).toBe(200);
    const [upstreamUrl, opts] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/billing/stripe/auto-withdraw`);
    expect(opts.method).toBe("PUT");
    expect(opts.headers.Authorization).toBe("Bearer privy-token-123");
    expect(JSON.parse(opts.body)).toEqual({ enabled: true });
  });

  it("preserves the coordinator error envelope", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamError(409, JSON.stringify({
        error: { type: "payout_destination_changed", message: "refresh" },
      }))
    );
    const { PUT } = await import("@/app/api/payments/stripe/auto-withdraw/route");
    const req = makeRequest("/api/payments/stripe/auto-withdraw", {
      method: "PUT",
      body: JSON.stringify({ enabled: true }),
    });

    const res = await PUT(req);

    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({
      error: { type: "payout_destination_changed", message: "refresh" },
    });
  });

  it("falls back to the Privy cookie", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ auto_withdraw_enabled: false })
    );
    const { PUT } = await import("@/app/api/payments/stripe/auto-withdraw/route");
    const req = makeRequest("/api/payments/stripe/auto-withdraw", {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        cookie: "privy-token=cookie-token",
      },
      body: JSON.stringify({ enabled: false }),
    });

    await PUT(req);

    const [, opts] = upstream.fetch.mock.calls[0];
    expect(opts.headers.Authorization).toBe("Bearer cookie-token");
  });
});

describe("GET /api/payments/usage", () => {
  it("proxies to coordinator /v1/payments/usage", async () => {
    const entries = {
      usage: [
        {
          request_id: "r1",
          model: "m",
          prompt_tokens: 10,
          completion_tokens: 20,
          cost_micro_usd: 100,
          timestamp: "2025-01-01T00:00:00Z",
        },
      ],
    };
    upstream.fetch.mockResolvedValueOnce(upstreamOk(entries));

    const { GET } = await import("@/app/api/payments/usage/route");
    const req = makeRequest("/api/payments/usage", {
      headers: {
        "x-api-key": "key-u",
      },
    });
    const res = await GET(req);

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.usage).toHaveLength(1);

    const [upstreamUrl, upstreamOpts] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/payments/usage`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer key-u");
  });

  it("returns upstream status on error", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamError(403));

    const { GET } = await import("@/app/api/payments/usage/route");
    const req = makeRequest("/api/payments/usage");
    const res = await GET(req);

    expect(res.status).toBe(403);
  });
});

describe("POST /api/invite/redeem", () => {
  it("forwards code to coordinator /v1/invite/redeem", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamOk({ credited_usd: "5.00", balance_usd: "15.00" })
    );

    const { POST } = await import("@/app/api/invite/redeem/route");
    const req = makeRequest("/api/invite/redeem", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": "key-inv",
      },
      body: JSON.stringify({ code: "INV-TEST1234" }),
    });
    const res = await POST(req);

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.credited_usd).toBe("5.00");

    const [upstreamUrl, upstreamOpts] = upstream.fetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/invite/redeem`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer key-inv");
    expect(JSON.parse(upstreamOpts.body)).toEqual({ code: "INV-TEST1234" });
  });

  it("passes through error responses", async () => {
    upstream.fetch.mockResolvedValueOnce(
      new Response(JSON.stringify({ error: { message: "Invalid code" } }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      })
    );

    const { POST } = await import("@/app/api/invite/redeem/route");
    const req = makeRequest("/api/invite/redeem", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: "INV-BAD" }),
    });
    const res = await POST(req);

    expect(res.status).toBe(404);
    const data = await res.json();
    expect(data.error.message).toBe("Invalid code");
  });
});
