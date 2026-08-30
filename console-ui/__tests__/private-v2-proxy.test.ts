import { describe, expect, it } from "vitest";
import { makeRequest, stubUpstreamFetch } from "./helpers/route-harness";
import { POST as preflightPost } from "@/app/api/private/preflight/route";
import { POST as privateRequestPost } from "@/app/api/private/requests/route";

const upstream = stubUpstreamFetch();
const SENTINEL = "PROMPT_MUST_NEVER_REACH_THE_PROXY";

function opaqueEnvelope(): string {
  return JSON.stringify({
    version: "private_v2",
    lease_id: "lease-1",
    request_id: "request-1",
    client_public_key: "Y2xpZW50LXB1YmxpYy1rZXk",
    nonce: "AAAAAAAAAAAAAAAA",
    ciphertext: "ZW5jcnlwdGVkLWJ5dGVz",
  });
}

describe("private-v2 same-origin proxies", () => {
  it("forwards preflight bytes and auth without decoding the body", async () => {
    const body = JSON.stringify({
      model: "model-a",
      endpoint: "chat.completions",
      stream: true,
      requested_max_output_tokens: 4096,
    });
    upstream.fetch.mockResolvedValueOnce(new Response("{\"version\":\"private_v2\"}", {
      headers: { "Content-Type": "application/json" },
    }));
    const response = await preflightPost(makeRequest("/api/private/preflight", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": "console-key",
        "x-darkbloom-route": "self",
      },
      body,
    }));

    const [url, init] = upstream.fetch.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.darkbloom.dev/v1/private/preflight");
    expect(new TextDecoder().decode(init.body as Uint8Array)).toBe(body);
    expect(init.headers).toMatchObject({
      Authorization: "Bearer console-key",
      "Content-Type": "application/json",
      "X-Darkbloom-Route": "self",
    });
    expect(await response.text()).toBe("{\"version\":\"private_v2\"}");
    expect(response.headers.get("x-darkbloom-privacy-tier")).toBe("private-v2-process-bound");
  });

  it("relays only the encrypted request envelope and never logs prompt plaintext", async () => {
    const body = opaqueEnvelope();
    expect(body).not.toContain(SENTINEL);
    const consoleCalls: unknown[][] = [];
    const originalLog = console.log;
    console.log = (...args: unknown[]) => { consoleCalls.push(args); };
    try {
      upstream.fetch.mockResolvedValueOnce(new Response(
        "data: {\"type\":\"private_chunk_v2\"}\n\n",
        { headers: { "Content-Type": "text/event-stream" } },
      ));
      const response = await privateRequestPost(makeRequest("/api/private/requests", {
        method: "POST",
        headers: { "content-type": "application/json", "x-api-key": "console-key" },
        body,
      }));

      const [url, init] = upstream.fetch.mock.calls[0] as [string, RequestInit];
      const forwarded = new TextDecoder().decode(init.body as Uint8Array);
      expect(url).toBe("https://api.darkbloom.dev/v1/private/requests");
      expect(forwarded).toBe(body);
      expect(forwarded).not.toContain(SENTINEL);
      expect(JSON.stringify(init.headers)).not.toContain(SENTINEL);
      expect(JSON.stringify(consoleCalls)).not.toContain(SENTINEL);
      expect(await response.text()).toContain("private_chunk_v2");
      expect(response.headers.get("cache-control")).toBe("no-cache, no-transform");
      expect(response.headers.get("x-darkbloom-privacy-tier")).toBe("private-v2-process-bound");
    } finally {
      console.log = originalLog;
    }
  });

  it("rejects missing auth before forwarding any request body", async () => {
    const response = await privateRequestPost(makeRequest("/api/private/requests", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: SENTINEL,
    }));
    expect(response.status).toBe(401);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  it("bounds chunked preflight bodies before upstream forwarding", async () => {
    const response = await preflightPost(makeRequest("/api/private/preflight", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": "console-key" },
      body: "x".repeat((64 * 1024) + 1),
    }));
    expect(response.status).toBe(413);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  it("rejects an oversized encrypted envelope from Content-Length before reading", async () => {
    const response = await privateRequestPost(makeRequest("/api/private/requests", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "content-length": String((24 * 1024 * 1024) + 1),
        "x-api-key": "console-key",
      },
      body: "{}",
    }));
    expect(response.status).toBe(413);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});
