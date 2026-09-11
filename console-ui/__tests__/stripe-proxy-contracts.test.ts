import { describe, expect, it } from "vitest";
import { POST as checkout } from "@/app/api/payments/stripe/checkout/route";
import { POST as onboard } from "@/app/api/payments/stripe/onboard/route";
import { POST as withdraw } from "@/app/api/payments/withdraw/stripe/route";
import { POST as dashboard } from "@/app/api/payments/stripe/dashboard/route";
import { DELETE as unlink } from "@/app/api/payments/stripe/account/route";
import { GET as status } from "@/app/api/payments/stripe/status/route";
import { GET as withdrawals } from "@/app/api/payments/stripe/withdrawals/route";
import { DEFAULT_COORD, makeRequest, stubUpstreamFetch, upstreamJson, upstreamOk } from "./helpers/route-harness";

const upstream = stubUpstreamFetch();
const stripePath = "/api/stripe";
const routes = [
  [checkout, "POST", "/v1/billing/stripe/create-session"],
  [onboard, "POST", "/v1/billing/stripe/onboard"],
  [withdraw, "POST", "/v1/billing/withdraw/stripe"],
  [dashboard, "POST", "/v1/billing/stripe/dashboard"],
  [unlink, "DELETE", "/v1/billing/stripe/account"],
  [status, "GET", "/v1/billing/stripe/status"],
  [withdrawals, "GET", "/v1/billing/stripe/withdrawals"],
] as const;

describe("Stripe proxy wire contracts", () => {
  it.each(routes)("forwards cookie auth and lets the coordinator enforce authorization", async (handler, method, path) => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({})).mockResolvedValueOnce(upstreamOk({}));
    await handler(makeRequest(stripePath, { method, headers: { cookie: "privy-token=session" } }));
    expect(upstream.fetch.mock.calls[0][0]).toBe(`${DEFAULT_COORD}${path}`);
    expect(upstream.fetch.mock.calls[0][1].headers.Authorization).toBe("Bearer session");
    await handler(makeRequest(stripePath, { method, headers: { "x-api-key": "not-a-session" } }));
    expect(upstream.fetch.mock.calls[1][1].headers.Authorization).toBeUndefined();
  });

  it.each(routes)("wraps upstream error text and preserves its failure status", async (handler, method) => {
    const body = '{"error":{"message":"declined"}}';
    upstream.fetch.mockResolvedValueOnce(new Response(body, { status: 422 }));
    const response = await handler(makeRequest(stripePath, { method }));
    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: body });
  });

  it.each(routes)("normalizes successful status and tolerates non-JSON responses", async (handler, method) => {
    upstream.fetch.mockResolvedValueOnce(upstreamJson(201, { ok: true }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    const response = await handler(makeRequest(stripePath, { method }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(await (await handler(makeRequest(stripePath, { method }))).json()).toEqual({});
  });

  it.each([checkout, onboard, withdraw])("uses JSON fallback for malformed request bodies", async (handler) => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({}));
    await handler(makeRequest(stripePath, {
      method: "POST", body: "invalid json",
      headers: { authorization: "Bearer header", cookie: "privy-token=cookie" },
    }));
    expect(upstream.fetch.mock.calls[0][1]).toEqual({
      method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer header" }, body: "{}",
    });
  });

  it.each([[dashboard, "POST"], [unlink, "DELETE"]] as const)("does not manufacture a body for bodyless operations", async (handler, method) => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({}));
    await handler(makeRequest(stripePath, { method, body: "ignored" }));
    expect(upstream.fetch.mock.calls[0][1]).toEqual({ method, headers: {} });
  });

  it.each([[status, "refresh"], [withdrawals, "limit"]] as const)("forwards only the operation's selected query parameter", async (handler, query) => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({}));
    await handler(makeRequest(`/api/stripe?${query}=1&unrelated=secret`));
    expect(upstream.fetch.mock.calls[0][0].endsWith(`?${query}=1`)).toBe(true);
  });
});
