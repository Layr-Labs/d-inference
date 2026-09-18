import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { streamChat } from "./stream";
import type { StreamCallbacks } from "../api/types";
import { STORAGE_KEYS } from "../storage-keys";

const encryption = vi.hoisted(() => ({ enabled: false, unseal: vi.fn(), sse: vi.fn(), seal: vi.fn() }));
vi.mock("../encryption", () => ({
  SEALED_CONTENT_TYPE: "application/eigeninference-sealed+json", clearCoordinatorKeyCache: vi.fn(),
  getCoordinatorKey: async () => ({ publicKey: new Uint8Array([1]) }), isEncryptionEnabled: () => encryption.enabled,
  sealRequest: encryption.seal, unsealResponse: encryption.unseal, unsealSseEvent: encryption.sse,
}));
const fetchMock = vi.fn();
const session = { auth: { kind: "session", token: "fresh-session" } } as const;
function callbacks(): StreamCallbacks {
  return { onToken: vi.fn(), onThinking: vi.fn(), onMetrics: vi.fn(), onDone: vi.fn(), onError: vi.fn() };
}
beforeEach(() => {
  vi.clearAllMocks(); localStorage.clear(); encryption.enabled = false;
  vi.stubGlobal("fetch", fetchMock);
  encryption.seal.mockReturnValue({ envelopeJson: "opaque sealed body", ephemeralPrivateKey: new Uint8Array([2]) });
});
afterEach(() => vi.unstubAllGlobals());

describe("explicit chat credentials and trial errors", () => {
  it("uses only session credentials despite a saved API key, preserving SSE parsing", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "unrelated-secret");
    const cb = callbacks();
    fetchMock.mockResolvedValue(new Response('data: {"choices":[{"delta":{"content":"Hello"}}]}\n\ndata: [DONE]\n\n'));
    await streamChat([{ role: "user", content: "hi" }], "bonsai", cb, undefined, session);
    const init = fetchMock.mock.calls[0][1];
    expect(init.headers).toEqual({ "Content-Type": "application/json", Authorization: "Bearer fresh-session" });
    expect(init.body).not.toContain("fresh-session");
    expect(JSON.stringify(Array.from({ length: localStorage.length }, (_, index) => localStorage.getItem(localStorage.key(index)!)))).not.toContain("fresh-session");
    expect(cb.onToken).toHaveBeenCalledWith("Hello");
    expect(cb.onDone).toHaveBeenCalledOnce();
  });
  it("keeps explicit selected key and owner routing without session credentials", async () => {
    fetchMock.mockResolvedValue(new Response("data: [DONE]\n\n"));
    await streamChat([], "bonsai", callbacks(), undefined, { auth: { kind: "api-key", key: "restricted-key" }, selfRoute: true });
    expect(fetchMock.mock.calls[0][1].headers).toEqual({ "Content-Type": "application/json", "x-api-key": "restricted-key", "X-Darkbloom-Route": "prefer" });
  });
  it.each([
    [402, "bonsai_trial_exhausted", "Hey, you've used all 5 million free tokens for Bonsai 2."],
    [402, "bonsai_trial_request_too_large", "Try a shorter conversation or a smaller response."],
    [429, "bonsai_trial_busy", "Wait for your other request to finish."],
    [503, "bonsai_trial_unavailable", "Free Bonsai 2 chat is temporarily unavailable."],
  ])("preserves %s %s before generic billing copy", async (status, code, message) => {
    const cb = callbacks();
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ error: { code, message } }), { status }));
    await streamChat([], "bonsai", cb, undefined, session);
    expect(cb.onError).toHaveBeenCalledWith(message);
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(cb.onDone).not.toHaveBeenCalled();
  });
  it("keeps ordinary paid 402 handling", async () => {
    const cb = callbacks();
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ error: { message: "balance too low" } }), { status: 402 }));
    await streamChat([], "other", cb, undefined, session);
    expect(cb.onError).toHaveBeenCalledWith("Insufficient credits — buy credits in Billing to continue");
  });
  it.each(["session", "api-key"] as const)("401 in %s mode never mints or falls back", async (kind) => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "restricted-key");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "selected");
    const expired = vi.fn(); window.addEventListener("darkbloom-key-expired", expired);
    const cb = callbacks(); fetchMock.mockResolvedValue(new Response("expired", { status: 401 }));
    await streamChat([], "bonsai", cb, undefined, { auth: kind === "session" ? session.auth : { kind, key: "restricted-key" } });
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(expired).not.toHaveBeenCalled();
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBe("restricted-key");
    expect(cb.onError).toHaveBeenCalledWith(kind === "session" ? "Session expired. Please sign in again." : "Your selected API key is invalid or expired. Select another key in the API Console.");
    window.removeEventListener("darkbloom-key-expired", expired);
  });
  it("seals session requests and decrypts an exhaustion error", async () => {
    encryption.enabled = true;
    const message = "Hey, you've used all 5 million free tokens for Bonsai 2.";
    encryption.unseal.mockReturnValue(new TextEncoder().encode(JSON.stringify({ error: { code: "bonsai_trial_exhausted", message } })));
    fetchMock.mockResolvedValue(new Response("ciphertext", { status: 402, headers: { "content-type": "application/eigeninference-sealed+json" } }));
    const cb = callbacks(); await streamChat([], "bonsai", cb, undefined, session);
    expect(fetchMock.mock.calls[0][1].body).toBe("opaque sealed body");
    expect(fetchMock.mock.calls[0][1].headers.Authorization).toBe("Bearer fresh-session");
    expect(cb.onError).toHaveBeenCalledWith(message);
  });
  it("decrypts sealed SSE tokens and done with session auth", async () => {
    encryption.enabled = true;
    encryption.sse.mockReturnValueOnce('data: {"choices":[{"delta":{"content":"Private reply"}}]}').mockReturnValueOnce("data: [DONE]");
    fetchMock.mockResolvedValue(new Response("data: cipher1\n\ndata: cipher2\n\n", { headers: { "x-eigen-sealed": "true" } }));
    const cb = callbacks(); await streamChat([], "bonsai", cb, undefined, session);
    expect(cb.onToken).toHaveBeenCalledWith("Private reply");
    expect(cb.onDone).toHaveBeenCalledOnce();
    expect(cb.onError).not.toHaveBeenCalled();
  });
});
