import { NextRequest } from "next/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GET } from "./route";

afterEach(() => vi.unstubAllGlobals());
describe("Public model demand proxy", () => {
  it("rejects unbounded windows before contacting the coordinator", async () => {
    const fetcher = vi.fn(); vi.stubGlobal("fetch", fetcher);
    const response = await GET(new NextRequest("http://localhost/api/network/model-demand?window=all"));
    expect(response.status).toBe(400); expect(fetcher).not.toHaveBeenCalled();
  });
  it("forwards only the supported window and caches successful aggregates", async () => {
    const fetcher = vi.fn().mockResolvedValue(Response.json({ models: [] })); vi.stubGlobal("fetch", fetcher);
    const response = await GET(new NextRequest("http://localhost/api/network/model-demand?window=7d&consumer=private&until=tomorrow"));
    expect(response.status).toBe(200);
    expect(fetcher.mock.calls[0][0]).toMatch(/\/v1\/network\/model-demand\?window=7d$/);
    expect(response.headers.get("Cache-Control")).toContain("s-maxage=60");
  });
  it.each(["http", "network", "json"])("does not cache or expose %s upstream errors", async kind => {
    const fetcher = vi.fn();
    if (kind === "network") fetcher.mockRejectedValue(new Error("private host"));
    else if (kind === "json") fetcher.mockResolvedValue(new Response("private error"));
    else fetcher.mockResolvedValue(new Response("private error", { status: 500 }));
    vi.stubGlobal("fetch", fetcher);
    const response = await GET(new NextRequest("http://localhost/api/network/model-demand"));
    expect(response.status).toBe(503); expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.text()).not.toContain("private");
  });
});
