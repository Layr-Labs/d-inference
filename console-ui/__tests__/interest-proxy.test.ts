import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest, NextResponse } from "next/server";
import { GET, POST } from "@/app/api/interest/small-models/route";

const fetchMock = vi.fn<typeof fetch>();
beforeEach(() => { vi.stubGlobal("fetch", fetchMock); vi.stubEnv("NEXT_PUBLIC_COORDINATOR_URL", "http://coordinator.invalid"); fetchMock.mockReset(); });
afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs(); });
const request = (method: string, auth = true) => new NextRequest("http://console.invalid/api/interest/small-models?account_id=other", {
  method, headers: auth ? { Authorization: "Bearer synthetic-session" } : {},
  ...(method === "POST" ? { body: '{"mac_type":"MacBook Pro","chip":"M1","ram_gb":16}' } : {}),
});

describe("503-P01 real Next interest proxy", () => {
  it("rejects missing auth before reading a body or contacting upstream", async () => {
    const req = request("POST", false); const body = vi.spyOn(req, "text");
    expect((await POST(req)).status).toBe(401);
    expect(body).not.toHaveBeenCalled(); expect(fetchMock).not.toHaveBeenCalled();
  });
  it("forwards authenticated body to fixed path and constructs an actual empty204", async () => {
    fetchMock.mockResolvedValue(new Response(null, { status: 204 }));
    const response = await POST(request("POST"));
    expect(response).toBeInstanceOf(NextResponse); expect(response.status).toBe(204); expect(await response.text()).toBe("");
    expect(fetchMock).toHaveBeenCalledWith("http://coordinator.invalid/v1/interest/small-models", expect.objectContaining({
      method: "POST", headers: { Authorization: "Bearer synthetic-session", "Content-Type": "application/json" },
      body: '{"mac_type":"MacBook Pro","chip":"M1","ram_gb":16}', cache: "no-store",
    }));
  });
  it("preserves error body/status and retry-after", async () => {
    fetchMock.mockResolvedValue(new Response('{"error":"limited"}', { status: 429, headers: { "Retry-After": "5" } }));
    const response = await POST(request("POST"));
    expect(response.status).toBe(429); expect(await response.text()).toBe('{"error":"limited"}'); expect(response.headers.get("retry-after")).toBe("5");
  });
  it("GET uses no-store and does not forward account selection from the caller", async () => {
    fetchMock.mockResolvedValue(Response.json({ ram_gb: 16 }));
    const response = await GET(request("GET"));
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(fetchMock).toHaveBeenCalledWith("http://coordinator.invalid/v1/interest/small-models", expect.objectContaining({ method: "GET", cache: "no-store" }));
  });
});
