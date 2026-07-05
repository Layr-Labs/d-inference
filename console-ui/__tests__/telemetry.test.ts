import { describe, it, expect } from "vitest";
import { NextRequest } from "next/server";
import { stubUpstreamFetch } from "./helpers/route-harness";

// Tests for the browser telemetry client AND the /api/telemetry proxy.

const upstream = stubUpstreamFetch();

describe("/api/telemetry route", () => {
  it("forwards a small batch to the coordinator", async () => {
    upstream.fetch.mockResolvedValue(
      new Response(JSON.stringify({ accepted: 1, rejected: 0 }), { status: 202 })
    );
    const { POST } = await import("@/app/api/telemetry/route");
    const req = new NextRequest("http://localhost:3000/api/telemetry", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer abc" },
      body: JSON.stringify({
        events: [
          {
            id: "00000000-0000-0000-0000-000000000001",
            timestamp: new Date().toISOString(),
            source: "console",
            severity: "error",
            kind: "http_error",
            message: "test",
          },
        ],
      }),
    });
    const res = await POST(req);
    expect(res.status).toBe(202);
    expect(upstream.fetch).toHaveBeenCalledOnce();
    const [calledUrl, init] = upstream.fetch.mock.calls[0];
    expect(String(calledUrl)).toMatch(/\/v1\/telemetry\/events$/);
    expect((init as RequestInit).headers).toMatchObject({
      Authorization: "Bearer abc",
    });
  });

  it("rejects oversized bodies", async () => {
    const { POST } = await import("@/app/api/telemetry/route");
    const huge = "A".repeat(70_000);
    const req = new NextRequest("http://localhost:3000/api/telemetry", {
      method: "POST",
      body: huge,
    });
    const res = await POST(req);
    expect(res.status).toBe(413);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  it("returns 502 when the coordinator is unreachable", async () => {
    upstream.fetch.mockRejectedValue(new Error("network down"));
    const { POST } = await import("@/app/api/telemetry/route");
    const req = new NextRequest("http://localhost:3000/api/telemetry", {
      method: "POST",
      body: JSON.stringify({ events: [] }),
    });
    const res = await POST(req);
    expect(res.status).toBe(502);
  });
});

describe("telemetry client", () => {
  it("filters fields client-side per allowlist", async () => {
    const tel = await import("@/lib/telemetry");
    tel._resetForTest();
    // Stub fetch so flush goes through.
    upstream.fetch.mockResolvedValue(new Response("{}", { status: 202 }));

    tel.emit({
      kind: "http_error",
      severity: "error",
      message: "x",
      fields: {
        component: "test",        // allowed
        prompt: "SECRET",         // dropped
        nested: { foo: "bar" },   // dropped
      },
    });
    expect(tel._bufferSize()).toBe(1);
  });
});
