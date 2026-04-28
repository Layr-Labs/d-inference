import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { NextRequest } from "next/server";

// ---------------------------------------------------------------------------
// We test each API route handler by importing its exported function directly
// and calling it with a synthetic NextRequest.
// ---------------------------------------------------------------------------

// Mock global fetch before importing route handlers (they use fetch at the
// module level for forwarding to the coordinator).
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

// Helpers -----------------------------------------------------------------

function makeRequest(
  url: string,
  init?: { method?: string; headers?: Record<string, string>; body?: string }
): NextRequest {
  return new NextRequest(new URL(url, "http://localhost:3000"), {
    method: init?.method ?? "GET",
    headers: init?.headers ?? {},
    ...(init?.body ? { body: init.body } : {}),
  });
}

function upstreamOk(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function upstreamError(status: number, body = "error"): Response {
  return new Response(body, { status });
}

// =========================================================================
// GET /api/me/providers
// =========================================================================

describe("GET /api/me/providers", () => {
  it("proxies auth to coordinator /v1/me/providers", async () => {
    upstreamFetch.mockResolvedValueOnce(
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
    const [upstreamUrl, upstreamOpts] = upstreamFetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/me/providers`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer privy-token-123");
  });

  it("rejects missing auth", async () => {
    const { GET } = await import("@/app/api/me/providers/route");
    const req = makeRequest("/api/me/providers");
    const res = await GET(req);

    expect(res.status).toBe(401);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });
});

// =========================================================================
// GET /api/me/summary
// =========================================================================

describe("GET /api/me/summary", () => {
  it("proxies auth to coordinator /v1/me/summary", async () => {
    upstreamFetch.mockResolvedValueOnce(
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
    const [upstreamUrl, upstreamOpts] = upstreamFetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/me/summary`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer privy-token-123");
  });
});

// =========================================================================
// POST /api/chat
// =========================================================================

describe("POST /api/chat", () => {
  it("forwards routing preference header and query param to coordinator", async () => {
    upstreamFetch.mockResolvedValueOnce(
      new Response("ok", {
        status: 200,
        headers: { "Content-Type": "text/plain" },
      })
    );

    const { POST } = await import("@/app/api/chat/route");
    const req = makeRequest("/api/chat?routing_preference=cost", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": "key123",
        "x-darkbloom-routing-preference": "cost",
      },
      body: JSON.stringify({ model: "model-a", messages: [] }),
    });
    const res = await POST(req);

    expect(res.status).toBe(200);
    const [upstreamUrl, upstreamOpts] = upstreamFetch.mock.calls[0];
    expect(String(upstreamUrl)).toBe(`${DEFAULT_COORD}/v1/chat/completions?routing_preference=cost`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer key123");
    expect(upstreamOpts.headers["X-Darkbloom-Routing-Preference"]).toBe("cost");
    expect(JSON.parse(upstreamOpts.body)).toEqual({ model: "model-a", messages: [] });
  });
});

// =========================================================================
// GET /api/payments/balance
// =========================================================================

describe("GET /api/payments/balance", () => {
  it("proxies to coordinator /v1/payments/balance", async () => {
    upstreamFetch.mockResolvedValueOnce(
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

    expect(upstreamFetch).toHaveBeenCalledOnce();
    const [upstreamUrl, upstreamOpts] = upstreamFetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/payments/balance`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer key123");

    expect(res.status).toBe(200);
    expect(data.balance_usd).toBe(0.001);
  });

  it("ignores x-coordinator-url header (SSRF prevention)", async () => {
    upstreamFetch.mockResolvedValueOnce(
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

    const [upstreamUrl] = upstreamFetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/payments/balance`);
  });

  it("returns upstream status on error", async () => {
    upstreamFetch.mockResolvedValueOnce(upstreamError(401));

    const { GET } = await import("@/app/api/payments/balance/route");
    const req = makeRequest("/api/payments/balance");
    const res = await GET(req);

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toContain("401");
  });

  it("uses default coordinator URL when header missing", async () => {
    upstreamFetch.mockResolvedValueOnce(
      upstreamOk({ balance_micro_usd: 0, balance_usd: 0 })
    );

    const { GET } = await import("@/app/api/payments/balance/route");
    const req = makeRequest("/api/payments/balance");
    await GET(req);

    const [upstreamUrl] = upstreamFetch.mock.calls[0];
    expect(upstreamUrl).toContain("/v1/payments/balance");
  });
});

// =========================================================================
// POST /api/payments/stripe/checkout
// =========================================================================

describe("POST /api/payments/stripe/checkout", () => {
  it("forwards body and auth to coordinator /v1/billing/stripe/create-session", async () => {
    upstreamFetch.mockResolvedValueOnce(
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

    const [upstreamUrl, upstreamOpts] = upstreamFetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/billing/stripe/create-session`);
    expect(upstreamOpts.method).toBe("POST");
    expect(upstreamOpts.headers["Content-Type"]).toBe("application/json");
    expect(upstreamOpts.headers.Authorization).toBe("Bearer privy-token-123");
    expect(JSON.parse(upstreamOpts.body)).toEqual({ amount_usd: "10" });
  });

  it("returns error on upstream failure", async () => {
    upstreamFetch.mockResolvedValueOnce(upstreamError(400, "bad request"));

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

// =========================================================================
// GET /api/payments/usage
// =========================================================================

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
    upstreamFetch.mockResolvedValueOnce(upstreamOk(entries));

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

    const [upstreamUrl, upstreamOpts] = upstreamFetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/payments/usage`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer key-u");
  });

  it("returns upstream status on error", async () => {
    upstreamFetch.mockResolvedValueOnce(upstreamError(403));

    const { GET } = await import("@/app/api/payments/usage/route");
    const req = makeRequest("/api/payments/usage");
    const res = await GET(req);

    expect(res.status).toBe(403);
  });
});

// =========================================================================
// POST /api/invite/redeem
// =========================================================================

describe("POST /api/invite/redeem", () => {
  it("forwards code to coordinator /v1/invite/redeem", async () => {
    upstreamFetch.mockResolvedValueOnce(
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

    const [upstreamUrl, upstreamOpts] = upstreamFetch.mock.calls[0];
    expect(upstreamUrl).toBe(`${DEFAULT_COORD}/v1/invite/redeem`);
    expect(upstreamOpts.headers.Authorization).toBe("Bearer key-inv");
    expect(JSON.parse(upstreamOpts.body)).toEqual({ code: "INV-TEST1234" });
  });

  it("passes through error responses", async () => {
    upstreamFetch.mockResolvedValueOnce(
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
