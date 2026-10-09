import { describe, expect, it, vi } from "vitest";
import { GET as listKeys, POST as createKey } from "@/app/api/keys/route";
import { GET as inspectKey, PATCH as updateKey } from "@/app/api/keys/[id]/route";
import { POST as rotateKey } from "@/app/api/keys/[id]/rotate/route";
import { DELETE as removeMachine } from "@/app/api/me/providers/[id]/route";
import { POST as approveDevice } from "@/app/api/device/approve/route";
import { DEFAULT_COORD, makeRequest, stubUpstreamFetch, upstreamOk } from "./helpers/route-harness";

const upstream = stubUpstreamFetch();
const headerToken = "Bearer header-token";
const auth = { authorization: headerToken, cookie: "privy-token=cookie-token" };
const resource = { params: Promise.resolve({ id: "key /?#%" }) };

describe("account proxy wire contracts", () => {
  it("rejects before reading a body or waiting for dynamic params", async () => {
    const req = makeRequest("/api/keys/key", { method: "PATCH", body: "{}" });
    const read = vi.spyOn(req, "text");
    const response = await updateKey(req, { params: new Promise(() => {}) });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "missing privy token" });
    expect(read).not.toHaveBeenCalled();
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  it.each([listKeys, (req: Parameters<typeof inspectKey>[0]) => inspectKey(req, resource)])(
    "prefers the header to the cookie and disables caching for account reads",
    async (handler) => {
      upstream.fetch.mockResolvedValueOnce(upstreamOk({}));
      await handler(makeRequest("/api/keys", { headers: auth }));
      expect(upstream.fetch.mock.calls[0][1]).toEqual({
        headers: { Authorization: headerToken }, cache: "no-store",
      });
    },
  );

  it.each([createKey, approveDevice])("forwards raw bodies without parsing or rewriting", async (handler) => {
    const body = '  {"limit_usd":null, "unknown": [1, 2]}\n';
    upstream.fetch.mockResolvedValueOnce(new Response("once-only secret", {
      status: 201, headers: { "Content-Type": "text/plain", "X-Internal": "hidden" },
    }));
    const response = await handler(makeRequest("/api/account", { method: "POST", headers: auth, body }));
    expect(upstream.fetch.mock.calls[0][1].body).toBe(body);
    expect(response.status).toBe(201);
    expect(response.headers.get("content-type")).toBe("text/plain");
    expect(response.headers.get("x-internal")).toBeNull();
    expect(await response.text()).toBe("once-only secret");
  });

  it("substitutes an empty object only for an empty account body", async () => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({}));
    await createKey(makeRequest("/api/keys", { method: "POST", headers: auth }));
    expect(upstream.fetch.mock.calls[0][1].body).toBe("{}");
  });

  it.each([
    [rotateKey, "POST", "/v1/keys/key%20%2F%3F%23%25/rotate"],
    [removeMachine, "DELETE", "/v1/me/providers/key%20%2F%3F%23%25"],
  ] as const)("keeps bodyless resource operations bodyless and IDs opaque", async (handler, method, path) => {
    upstream.fetch.mockResolvedValueOnce(upstreamOk({}));
    await handler(makeRequest("/api/resource", { method, headers: auth, body: "ignored" }), resource);
    expect(upstream.fetch).toHaveBeenCalledWith(`${DEFAULT_COORD}${path}`, {
      method, headers: { Authorization: headerToken },
    });
  });
});
