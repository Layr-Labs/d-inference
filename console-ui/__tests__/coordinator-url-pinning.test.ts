import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { NextRequest } from "next/server";

// Regression: server proxy routes must resolve the coordinator URL
// from the build-time constant only. A client-supplied `x-coordinator-url`
// header must never choose the upstream origin — it turns the Next server
// into an SSRF proxy and forwards Privy session tokens to that origin.
//
// Each case sends an attacker-controlled header (plus a privy-token cookie
// for the routes that forward it) and asserts the upstream fetch went to the
// pinned coordinator.

const DEFAULT_COORD = "https://api.darkbloom.dev";
const ATTACKER = "https://attacker.example.com";

let upstreamFetch: ReturnType<typeof vi.fn>;

beforeEach(() => {
  upstreamFetch = vi.fn().mockResolvedValue(
    new Response(JSON.stringify({}), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    })
  );
  vi.stubGlobal("fetch", upstreamFetch);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.resetModules();
});

function makeRequest(
  url: string,
  init?: { method?: string; body?: string }
): NextRequest {
  return new NextRequest(new URL(url, "http://localhost:3000"), {
    method: init?.method ?? "GET",
    headers: {
      "x-coordinator-url": ATTACKER,
      cookie: "privy-token=privy-tok-123",
      ...(init?.body ? { "content-type": "application/json" } : {}),
    },
    ...(init?.body ? { body: init.body } : {}),
  });
}

interface RouteCase {
  name: string;
  importPath: () => Promise<{
    POST?: (req: NextRequest) => Promise<Response>;
    GET?: (req: NextRequest) => Promise<Response>;
  }>;
  method: "GET" | "POST";
  requestPath: string;
  upstreamPath: string;
  body?: string;
}

const CASES: RouteCase[] = [
  {
    name: "POST /api/payments/stripe/checkout",
    importPath: () => import("@/app/api/payments/stripe/checkout/route"),
    method: "POST",
    requestPath: "/api/payments/stripe/checkout",
    upstreamPath: "/v1/billing/stripe/create-session",
    body: JSON.stringify({ amount_usd: 10 }),
  },
  {
    name: "GET /api/payments/stripe/status",
    importPath: () => import("@/app/api/payments/stripe/status/route"),
    method: "GET",
    requestPath: "/api/payments/stripe/status",
    upstreamPath: "/v1/billing/stripe/status",
  },
  {
    name: "POST /api/payments/stripe/onboard",
    importPath: () => import("@/app/api/payments/stripe/onboard/route"),
    method: "POST",
    requestPath: "/api/payments/stripe/onboard",
    upstreamPath: "/v1/billing/stripe/onboard",
    body: JSON.stringify({ country: "US" }),
  },
  {
    name: "GET /api/payments/stripe/withdrawals",
    importPath: () => import("@/app/api/payments/stripe/withdrawals/route"),
    method: "GET",
    requestPath: "/api/payments/stripe/withdrawals",
    upstreamPath: "/v1/billing/stripe/withdrawals",
  },
  {
    name: "POST /api/payments/withdraw/stripe",
    importPath: () => import("@/app/api/payments/withdraw/stripe/route"),
    method: "POST",
    requestPath: "/api/payments/withdraw/stripe",
    upstreamPath: "/v1/billing/withdraw/stripe",
    body: JSON.stringify({ amount_usd: 5, method: "standard" }),
  },
  {
    name: "POST /api/telemetry",
    importPath: () => import("@/app/api/telemetry/route"),
    method: "POST",
    requestPath: "/api/telemetry",
    upstreamPath: "/v1/telemetry/events",
    body: JSON.stringify({ events: [] }),
  },
];

describe("coordinator URL pinning", () => {
  for (const c of CASES) {
    it(`${c.name} ignores x-coordinator-url`, async () => {
      const mod = await c.importPath();
      const handler = c.method === "GET" ? mod.GET! : mod.POST!;
      const res = await handler(
        makeRequest(c.requestPath, { method: c.method, body: c.body })
      );

      expect(res.status).toBe(200);
      expect(upstreamFetch).toHaveBeenCalledTimes(1);
      const upstreamUrl = String(upstreamFetch.mock.calls[0][0]);
      expect(upstreamUrl.startsWith(`${DEFAULT_COORD}${c.upstreamPath}`)).toBe(
        true
      );
      expect(upstreamUrl).not.toContain("attacker.example.com");
    });
  }
});
