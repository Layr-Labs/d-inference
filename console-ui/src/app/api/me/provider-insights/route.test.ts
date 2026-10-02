import { afterEach, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { GET } from "./route";
afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

it("requires credentials and rejects unbounded windows without fetching", async () => {
  const fetchMock = vi.fn(); vi.stubGlobal("fetch", fetchMock);
  expect((await GET(new NextRequest("http://localhost/api/me/provider-insights"))).status).toBe(401);
  expect((await GET(new NextRequest("http://localhost/api/me/provider-insights?window=all", { headers: { Authorization: "Bearer test-only" } }))).status).toBe(400);
  expect(fetchMock).not.toHaveBeenCalled();
});
it("forwards only the window and caller credential with no shared caching", async () => {
  vi.stubEnv("NEXT_PUBLIC_COORDINATOR_URL", "http://127.0.0.1:4322");
  const fetchMock = vi.fn().mockResolvedValue(new Response('{"window":"30d"}', { status: 200 }));
  vi.stubGlobal("fetch", fetchMock);
  const response = await GET(new NextRequest("http://localhost/api/me/provider-insights?window=30d&account_id=someone-else", { headers: { Authorization: "Bearer test-only" } }));
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("private, no-store");
  expect(fetchMock.mock.calls[0][0]).toBe("http://127.0.0.1:4322/v1/me/provider-insights?window=30d");
  expect(fetchMock.mock.calls[0][1]).toMatchObject({ headers: { Authorization: "Bearer test-only" }, cache: "no-store" });
});
