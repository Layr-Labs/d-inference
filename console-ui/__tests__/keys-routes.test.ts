import { describe, it, expect } from "vitest";
import {
  DEFAULT_COORD,
  makeRequest,
  stubUpstreamFetch,
  upstreamJson,
  upstreamOk,
} from "./helpers/route-harness";

// Proxy tests for the API-key management route handlers
// (/api/keys, /api/keys/[id], /api/keys/[id]/rotate).

const upstream = stubUpstreamFetch();

describe("/api/keys", () => {
  it("GET proxies Privy auth to coordinator /v1/keys and ignores x-coordinator-url", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({ object: "list", data: [] }));

    const { GET } = await import("@/app/api/keys/route");
    const req = makeRequest("/api/keys", {
      headers: {
        authorization: "Bearer privy-1",
        "x-coordinator-url": "https://attacker.example.com",
      },
    });
    const res = await GET(req);

    expect(res.status).toBe(200);
    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/keys`);
    expect(opts.headers.Authorization).toBe("Bearer privy-1");
  });

  it("GET falls back to the privy-token cookie", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({ object: "list", data: [] }));

    const { GET } = await import("@/app/api/keys/route");
    const req = makeRequest("/api/keys", {
      headers: { cookie: "privy-token=cookie-tok" },
    });
    const res = await GET(req);

    expect(res.status).toBe(200);
    const [, opts] = upstream.fetch.mock.calls[0];
    expect(opts.headers.Authorization).toBe("Bearer cookie-tok");
  });

  it("GET rejects missing auth with 401", async () => {
    const { GET } = await import("@/app/api/keys/route");
    const res = await GET(makeRequest("/api/keys"));

    expect(res.status).toBe(401);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  it("POST forwards the body and passes through the once-only secret", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamJson(201, { key: "sk-db-secret", data: { id: "key_1", name: "prod" } })
    );

    const { POST } = await import("@/app/api/keys/route");
    const req = makeRequest("/api/keys", {
      method: "POST",
      headers: { "Content-Type": "application/json", authorization: "Bearer privy-1" },
      body: JSON.stringify({ name: "prod", limit_usd: 5 }),
    });
    const res = await POST(req);

    expect(res.status).toBe(201);
    const data = await res.json();
    expect(data.key).toBe("sk-db-secret");

    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/keys`);
    expect(opts.method).toBe("POST");
    expect(opts.headers.Authorization).toBe("Bearer privy-1");
    expect(JSON.parse(opts.body)).toEqual({ name: "prod", limit_usd: 5 });
  });

  it("POST passes through upstream error status + JSON", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamJson(400, { error: { message: "bad name" } }));

    const { POST } = await import("@/app/api/keys/route");
    const req = makeRequest("/api/keys", {
      method: "POST",
      headers: { "Content-Type": "application/json", authorization: "Bearer privy-1" },
      body: JSON.stringify({}),
    });
    const res = await POST(req);

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error.message).toBe("bad name");
  });
});

describe("/api/keys/[id]", () => {
  const ctx = (id: string) => ({ params: Promise.resolve({ id }) });

  it("GET proxies to /v1/keys/{id}", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({ id: "key_1", name: "prod" }));

    const { GET } = await import("@/app/api/keys/[id]/route");
    const req = makeRequest("/api/keys/key_1", { headers: { authorization: "Bearer privy-1" } });
    const res = await GET(req, ctx("key_1"));

    expect(res.status).toBe(200);
    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/keys/key_1`);
    expect(opts.headers.Authorization).toBe("Bearer privy-1");
  });

  it("PATCH forwards the body (including null to clear a field)", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({ id: "key_1", disabled: true }));

    const { PATCH } = await import("@/app/api/keys/[id]/route");
    const req = makeRequest("/api/keys/key_1", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", authorization: "Bearer privy-1" },
      body: JSON.stringify({ disabled: true, limit_usd: null }),
    });
    const res = await PATCH(req, ctx("key_1"));

    expect(res.status).toBe(200);
    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/keys/key_1`);
    expect(opts.method).toBe("PATCH");
    expect(JSON.parse(opts.body)).toEqual({ disabled: true, limit_usd: null });
  });

  it("DELETE proxies to /v1/keys/{id} and passes through the revoked status", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({ status: "revoked" }));

    const { DELETE } = await import("@/app/api/keys/[id]/route");
    const req = makeRequest("/api/keys/key_1", {
      method: "DELETE",
      headers: { authorization: "Bearer privy-1" },
    });
    const res = await DELETE(req, ctx("key_1"));

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.status).toBe("revoked");
    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/keys/key_1`);
    expect(opts.method).toBe("DELETE");
  });

  it("URL-encodes the key id", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({ id: "weird id" }));

    const { GET } = await import("@/app/api/keys/[id]/route");
    const req = makeRequest("/api/keys/weird", { headers: { authorization: "Bearer p" } });
    await GET(req, ctx("weird id"));

    const [url] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/keys/weird%20id`);
  });

  it("rejects missing auth with 401", async () => {
    const { DELETE } = await import("@/app/api/keys/[id]/route");
    const res = await DELETE(makeRequest("/api/keys/key_1", { method: "DELETE" }), ctx("key_1"));

    expect(res.status).toBe(401);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});

describe("/api/keys/[id]/rotate", () => {
  it("POST proxies to /v1/keys/{id}/rotate and returns the new secret", async () => {
    upstream.fetch.mockResolvedValueOnce(
      upstreamJson(200, { key: "sk-db-new", data: { id: "key_1" } })
    );

    const { POST } = await import("@/app/api/keys/[id]/rotate/route");
    const req = makeRequest("/api/keys/key_1/rotate", {
      method: "POST",
      headers: { authorization: "Bearer privy-1" },
    });
    const res = await POST(req, { params: Promise.resolve({ id: "key_1" }) });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.key).toBe("sk-db-new");

    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/keys/key_1/rotate`);
    expect(opts.method).toBe("POST");
    expect(opts.headers.Authorization).toBe("Bearer privy-1");
  });

  it("rejects missing auth with 401", async () => {
    const { POST } = await import("@/app/api/keys/[id]/rotate/route");
    const res = await POST(makeRequest("/api/keys/key_1/rotate", { method: "POST" }), {
      params: Promise.resolve({ id: "key_1" }),
    });

    expect(res.status).toBe(401);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});
