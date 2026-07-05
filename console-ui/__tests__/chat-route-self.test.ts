import { describe, it, expect } from "vitest";
import { NextRequest } from "next/server";
import { stubUpstreamFetch } from "./helpers/route-harness";

// Chat proxy: X-Darkbloom-Route forwarding (the "My Machine" wire signal).

const upstream = stubUpstreamFetch();

function streamResponse(): Response {
  return new Response("data: {}\n\n", {
    status: 200,
    headers: { "Content-Type": "text/event-stream" },
  });
}

function chatRequest(headers: Record<string, string>): NextRequest {
  return new NextRequest(new URL("/api/chat", "http://localhost:3000"), {
    method: "POST",
    headers,
    body: JSON.stringify({ model: "m", messages: [] }),
  });
}

describe("POST /api/chat self-route header forwarding", () => {
  it("forwards X-Darkbloom-Route: self upstream when the client sets it", async () => {
    upstream.fetch.mockResolvedValueOnce(streamResponse());
    const { POST } = await import("@/app/api/chat/route");
    await POST(
      chatRequest({
        "x-api-key": "k1",
        "content-type": "application/json",
        "x-darkbloom-route": "self",
      })
    );
    const opts = upstream.fetch.mock.calls[0][1];
    expect(opts.headers["X-Darkbloom-Route"]).toBe("self");
    expect(opts.headers.Authorization).toBe("Bearer k1");
  });

  it("omits the header when the client does not request self-route", async () => {
    upstream.fetch.mockResolvedValueOnce(streamResponse());
    const { POST } = await import("@/app/api/chat/route");
    await POST(
      chatRequest({ "x-api-key": "k1", "content-type": "application/json" })
    );
    const opts = upstream.fetch.mock.calls[0][1];
    expect(opts.headers["X-Darkbloom-Route"]).toBeUndefined();
  });
});
