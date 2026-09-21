// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { streamChat } from "./stream";
vi.mock("../encryption", () => ({ isEncryptionEnabled: () => false, SEALED_CONTENT_TYPE: "application/x-sealed", clearCoordinatorKeyCache: vi.fn(), getCoordinatorKey: vi.fn(), sealRequest: vi.fn(), unsealResponse: vi.fn(), unsealSseEvent: vi.fn() }));
vi.mock("../http/proxy-client", () => ({ proxyHeaders: (headers: Record<string, string>) => headers }));
afterEach(() => vi.unstubAllGlobals());
describe("frontend thinking default", () => {
  it.each([undefined, false])("sends the intended thinking flag (%s override)", async (override) => {
    const fetch = vi.fn(async () => new Response("data: [DONE]\n\n", { headers: { "Content-Type": "text/event-stream" } }));
    vi.stubGlobal("fetch", fetch);
    const callbacks = { onToken: vi.fn(), onThinking: vi.fn(), onMetrics: vi.fn(), onDone: vi.fn(), onError: vi.fn() };
    await streamChat([{ role: "user", content: "hello" }], "bonsai", callbacks, undefined, { enableThinking: override });
    const request = fetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(JSON.parse(request[1].body as string).enable_thinking).toBe(override ?? true);
    expect(callbacks.onError).not.toHaveBeenCalled();
  });
});
