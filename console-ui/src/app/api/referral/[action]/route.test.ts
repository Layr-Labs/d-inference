import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { GET, POST } from "./route";

const context = (action: string) => ({ params: Promise.resolve({ action }) });

describe("referral proxy", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("requires management authentication and does not accept a local inference key", async () => {
    const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
    const res = await POST(new NextRequest("https://console.test/api/referral/apply", { method: "POST", headers: { "x-api-key": "inference-secret" }, body: '{"code":"ALICE"}' }), context("apply"));
    expect(res.status).toBe(401); expect(fetch).not.toHaveBeenCalled();
  });

  it("forwards Privy auth and the exact payload while preserving rate limits", async () => {
    const body = { error: { type: "rate_limit_error", message: "Slow down" } };
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify(body), { status: 429, headers: { "Content-Type": "application/json", "Retry-After": "30" } }));
    vi.stubGlobal("fetch", fetch);
    const res = await POST(new NextRequest("https://console.test/api/referral/register", { method: "POST", headers: { authorization: "Bearer privy", "x-api-key": "inference-secret" }, body: '{"code":"ALICE"}' }), context("register"));
    expect(fetch).toHaveBeenCalledWith(expect.stringContaining("/v1/referral/register"), expect.objectContaining({ method: "POST", headers: { Authorization: "Bearer privy", "Content-Type": "application/json" }, body: '{"code":"ALICE"}', cache: "no-store" }));
    expect(res.status).toBe(429); expect(await res.json()).toEqual(body); expect(res.headers.get("retry-after")).toBe("30");
    expect(res.headers.get("cache-control")).toBe("private, no-store");
  });

  it("rejects unsupported routes and mutation through GET", async () => {
    const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
    for (const action of ["register", "apply", "../billing"]) {
      const res = await GET(new NextRequest("https://console.test/api/referral/info", { headers: { authorization: "Bearer privy" } }), context(action));
      expect(res.status).toBe(404);
    }
    expect(fetch).not.toHaveBeenCalled();
  });

  it("returns a retryable service error when upstream is unreachable", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("connect failed")));
    const res = await GET(new NextRequest("https://console.test/api/referral/info", { headers: { cookie: "privy-token=cookie-jwt" } }), context("info"));
    expect(res.status).toBe(502);
  });
});
