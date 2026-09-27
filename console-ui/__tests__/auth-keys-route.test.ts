import { describe, it, expect } from "vitest";
import {
  DEFAULT_COORD,
  makeRequest,
  stubUpstreamFetch,
  upstreamJson,
  upstreamOk,
} from "./helpers/route-harness";

const upstream = stubUpstreamFetch();

describe("/api/auth/keys", () => {
  it("POST proxies to coordinator /v1/auth/keys", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({ api_key: "sk-db-new", account_id: "acct-1" }));

    const { POST } = await import("@/app/api/auth/keys/route");
    const req = makeRequest("/api/auth/keys", {
      method: "POST",
      headers: { authorization: "Bearer privy-1" },
    });
    const res = await POST(req);

    expect(res.status).toBe(200);
    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/auth/keys`);
    expect(opts.method).toBe("POST");
    expect(opts.headers.Authorization).toBe("Bearer privy-1");
  });

  it("DELETE forwards the spare-key body to coordinator /v1/auth/keys", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamJson(200, { status: "revoked" }));

    const { DELETE } = await import("@/app/api/auth/keys/route");
    const req = makeRequest("/api/auth/keys", {
      method: "DELETE",
      headers: { authorization: "Bearer privy-1", "content-type": "application/json" },
      body: JSON.stringify({ key: "sk-db-untitled" }),
    });
    const res = await DELETE(req);

    expect(res.status).toBe(200);
    const [url, opts] = upstream.fetch.mock.calls[0];
    expect(url).toBe(`${DEFAULT_COORD}/v1/auth/keys`);
    expect(opts.method).toBe("DELETE");
    expect(opts.headers.Authorization).toBe("Bearer privy-1");
    expect(opts.body).toBe(JSON.stringify({ key: "sk-db-untitled" }));
  });
});
