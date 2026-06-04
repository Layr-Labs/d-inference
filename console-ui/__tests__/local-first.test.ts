import { describe, it, expect, vi } from "vitest";
import {
  buildLocalRequest,
  buildCoordinatorRequest,
  chatCompletionWithFallback,
  type FallbackConfig,
} from "@/lib/localFirst";

const COORD: Pick<FallbackConfig, "coordinatorURL" | "coordinatorApiKey"> = {
  coordinatorURL: "/api/chat",
  coordinatorApiKey: "dk-coord",
};

describe("buildLocalRequest", () => {
  it("targets <base>/chat/completions with the local bearer token", () => {
    const { url, init } = buildLocalRequest({ baseURL: "http://127.0.0.1:8000/v1", apiKey: "dk-local-x" }, { a: 1 });
    expect(url).toBe("http://127.0.0.1:8000/v1/chat/completions");
    expect((init.headers as Record<string, string>)["Authorization"]).toBe("Bearer dk-local-x");
    expect(init.body).toBe(JSON.stringify({ a: 1 }));
  });

  it("omits Authorization when the local server runs with --no-auth", () => {
    const { init } = buildLocalRequest({ baseURL: "http://127.0.0.1:8000/v1" }, {});
    expect((init.headers as Record<string, string>)["Authorization"]).toBeUndefined();
  });
});

describe("buildCoordinatorRequest", () => {
  it("sets the X-Darkbloom-Route: self opt-in and both auth header forms", () => {
    const { url, init } = buildCoordinatorRequest(COORD, { m: "x" });
    expect(url).toBe("/api/chat");
    const h = init.headers as Record<string, string>;
    expect(h["X-Darkbloom-Route"]).toBe("self");
    // Authorization for a raw coordinator; x-api-key for the /api/chat proxy.
    expect(h["Authorization"]).toBe("Bearer dk-coord");
    expect(h["x-api-key"]).toBe("dk-coord");
  });
});

describe("chatCompletionWithFallback", () => {
  const okResponse = () => new Response("ok", { status: 200 });

  it("uses the local endpoint when it is reachable", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    const cfg: FallbackConfig = { local: { baseURL: "http://127.0.0.1:8000/v1", apiKey: "dk-local" }, ...COORD };
    const { via } = await chatCompletionWithFallback({ x: 1 }, cfg, fetchImpl as unknown as typeof fetch);
    expect(via).toBe("local");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(fetchImpl.mock.calls[0][0]).toBe("http://127.0.0.1:8000/v1/chat/completions");
  });

  it("falls back to the coordinator self-route on a local connection failure", async () => {
    const fetchImpl = vi
      .fn()
      .mockRejectedValueOnce(new TypeError("fetch failed")) // local unreachable
      .mockResolvedValueOnce(okResponse()); // coordinator ok
    const cfg: FallbackConfig = { local: { baseURL: "http://127.0.0.1:8000/v1", apiKey: "dk-local" }, ...COORD };
    const { via } = await chatCompletionWithFallback({ x: 1 }, cfg, fetchImpl as unknown as typeof fetch);
    expect(via).toBe("coordinator");
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    const coordInit = fetchImpl.mock.calls[1][1];
    expect(coordInit.headers["X-Darkbloom-Route"]).toBe("self");
  });

  it("goes straight to the coordinator when no local endpoint is configured", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    const cfg: FallbackConfig = { local: null, ...COORD };
    const { via } = await chatCompletionWithFallback({ x: 1 }, cfg, fetchImpl as unknown as typeof fetch);
    expect(via).toBe("coordinator");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("does NOT reroute when the local server is reachable but returns an error", async () => {
    // A reachable local server that 500s surfaces its own error — no silent reroute.
    const fetchImpl = vi.fn().mockResolvedValue(new Response("boom", { status: 500 }));
    const cfg: FallbackConfig = { local: { baseURL: "http://127.0.0.1:8000/v1" }, ...COORD };
    const { via, response } = await chatCompletionWithFallback({ x: 1 }, cfg, fetchImpl as unknown as typeof fetch);
    expect(via).toBe("local");
    expect(response.status).toBe(500);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
});
