import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { GET as balance } from "./balance/route";
import { GET as usage } from "./usage/route";
import { POST as redeem } from "../invite/redeem/route";
import { POST as checkout } from "./stripe/checkout/route";
const upstream = vi.fn();
beforeEach(() => { upstream.mockReset().mockResolvedValue(Response.json({})); vi.stubGlobal("fetch", upstream); });
afterEach(() => vi.unstubAllGlobals());
describe("account operations without an inference key", () => {
  it.each([
    ["balance", balance, "GET"], ["usage", usage, "GET"], ["invite", redeem, "POST"], ["checkout", checkout, "POST"],
  ] as const)("uses the existing Privy cookie for %s", async (_name, handler, method) => {
    const req = new NextRequest("http://localhost/api/account", { method, headers: { cookie: "privy-token=session-token" }, ...(method === "POST" ? { body: "{}" } : {}) });
    expect((await handler(req)).status).toBe(200);
    expect(upstream.mock.calls[0][1].headers.Authorization).toBe("Bearer session-token");
  });
  it("retains explicit API-key balance access", async () => {
    await balance(new NextRequest("http://localhost/api/payments/balance", { headers: { "x-api-key": "selected-key" } }));
    expect(upstream.mock.calls[0][1].headers.Authorization).toBe("Bearer selected-key");
  });
});
