import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { POST } from "./route";

const upstream = vi.fn();
beforeEach(() => { vi.stubGlobal("fetch", upstream); upstream.mockReset(); });
afterEach(() => vi.unstubAllGlobals());
function request(headers: Record<string, string>, body = '{"model":"bonsai","stream":true}') {
  return new NextRequest("http://localhost/api/chat", { method: "POST", headers: { "content-type": "application/json", ...headers }, body });
}

describe("chat proxy authentication", () => {
  it.each([
    [{ authorization: "Bearer session-token" }, "Bearer session-token"],
    [{ "x-api-key": "selected-key" }, "Bearer selected-key"],
  ] as const)("forwards one explicit credential: %j", async (headers, expected) => {
    upstream.mockResolvedValue(new Response("data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } }));
    const response = await POST(request(headers));
    expect(upstream.mock.calls[0][1].headers).toEqual({ "Content-Type": "application/json", Authorization: expected });
    expect(await response.text()).toBe("data: [DONE]\n\n");
    expect(response.headers.get("authorization")).toBeNull();
    expect(response.headers.get("cache-control")).toBe("no-cache, no-transform");
  });
  it.each([
    [{}, 401], [{ authorization: "Basic invalid" }, 401],
    [{ authorization: "Bearer token", "x-api-key": "key" }, 400],
  ] as const)("rejects missing, malformed, or dual credentials: %j", async (headers, status) => {
    const response = await POST(request(headers));
    expect(response.status).toBe(status);
    expect(upstream).not.toHaveBeenCalled();
  });
  it("preserves sealed bytes, self-route restrictions, sealed errors and Retry-After", async () => {
    const body = '{\n "ciphertext" : "opaque bytes"\n}';
    upstream.mockResolvedValue(new Response("sealed-error", { status: 429, headers: { "content-type": "application/eigeninference-sealed+json", "x-eigen-sealed": "true", "retry-after": "3" } }));
    const response = await POST(request({ authorization: "Bearer token", "content-type": "application/eigeninference-sealed+json", "x-darkbloom-route": "self" }, body));
    expect(new TextDecoder().decode(upstream.mock.calls[0][1].body)).toBe(body);
    expect(upstream.mock.calls[0][1].headers["X-Darkbloom-Route"]).toBe("self");
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("3");
    expect(response.headers.get("x-eigen-sealed")).toBe("true");
    expect(await response.text()).toBe("sealed-error");
  });
  it("preserves successful non-streaming content type and status", async () => {
    upstream.mockResolvedValue(Response.json({ choices: [] }, { status: 201 }));
    const response = await POST(request({ authorization: "Bearer token" }, '{"stream":false}'));
    expect(response.status).toBe(201);
    expect(response.headers.get("content-type")).toContain("application/json");
    expect(await response.json()).toEqual({ choices: [] });
  });
  it("passes a non-streaming JSON trial error unchanged", async () => {
    const body = JSON.stringify({ error: { code: "bonsai_trial_exhausted", message: "Hey, you've used all 5 million free tokens for Bonsai 2." } });
    upstream.mockResolvedValue(new Response(body, { status: 402, headers: { "content-type": "application/json" } }));
    const response = await POST(request({ authorization: "Bearer token" }));
    expect(response.status).toBe(402);
    expect(await response.text()).toBe(body);
  });
});
