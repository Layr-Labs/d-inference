import { afterEach, describe, expect, it, vi } from "vitest";
import nacl from "tweetnacl";
import vector from "./fixtures/private-v2-golden.json";
import { decodeBase64Url, encodeBase64Url } from "@/lib/private-v2";
import { streamChat } from "@/lib/chat/stream";
import type { StreamCallbacks } from "@/lib/api/types";

vi.mock("@/lib/private-v2-attestation", () => ({
  verifyProcessCertificateAttestation: vi.fn(async (certificate: Record<string, string>) => ({
    backend: certificate.backend,
    platform: certificate.platform,
    providerVersion: certificate.provider_version,
    processPublicKey: certificate.process_public_key,
    releaseBinaryHash: certificate.release_binary_hash,
    sePublicKey: certificate.se_public_key,
    verifiedAt: certificate.verified_at,
    expiresAt: certificate.expires_at,
  })),
}));
vi.mock("@/lib/private-v2-release-policy", () => ({
  requirePinnedPrivateV2Release: vi.fn(),
}));

function callbacks() {
  return {
    value: {
      onToken: vi.fn(),
      onThinking: vi.fn(),
      onDone: vi.fn(),
      onError: vi.fn(),
      onMetrics: vi.fn(),
    } satisfies StreamCallbacks,
  };
}

function buffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function goldenPreflight() {
  return {
    version: "private_v2",
    lease_id: "lease-vector-1",
    request_id: "request-vector-1",
    route_id: "route-vector-1",
    model: "org/concrete-model",
    endpoint: "chat.completions",
    stream: true,
    process_public_key: vector.provider_public_key,
    kdf_salt: vector.kdf_salt,
    transcript_digest: vector.transcript_digest,
    process_certificate: vector.process_certificate,
    model_manifest_hash: "44".repeat(32),
    release_generation: 8,
    model_generation: 9,
    expires_at: "2030-01-02T03:04:35Z",
    requested_max_output_tokens: 4096,
    requires_vision: false,
    route_mode: "public",
    owner_binding: "",
  };
}

async function encryptedTerminal(clientPublicKey: string) {
  const digest = decodeBase64Url(vector.transcript_digest);
  const shared = nacl.scalarMult(
    decodeBase64Url(vector.provider_private_key),
    decodeBase64Url(clientPublicKey),
  );
  const material = await crypto.subtle.importKey("raw", buffer(shared), "HKDF", false, ["deriveKey"]);
  const prefix = new TextEncoder().encode("darkbloom/private-v2/response\0");
  const info = new Uint8Array(prefix.length + digest.length);
  info.set(prefix);
  info.set(digest, prefix.length);
  const key = await crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: buffer(decodeBase64Url(vector.kdf_salt)),
      info: buffer(info),
    },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const nonce = decodeBase64Url(vector.response_nonce);
  const aad = new Uint8Array(digest.length + 8);
  aad.set(digest);
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: buffer(nonce), additionalData: buffer(aad), tagLength: 128 },
    key,
    buffer(new TextEncoder().encode(vector.response_plaintext)),
  ));
  shared.fill(0);
  return {
    type: "private_chunk_v2",
    version: "private_v2",
    request_id: "request-vector-1",
    sequence: 0,
    terminal: true,
    nonce: vector.response_nonce,
    ciphertext: encodeBase64Url(ciphertext),
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("private-v2 chat transport", () => {
  it("completes only through private-v2 while the proxy body contains no prompt plaintext", async () => {
    vi.spyOn(Date, "now").mockReturnValue(Date.parse("2030-01-02T03:04:05Z"));
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      if (url === "/api/private/preflight") {
        return new Response(JSON.stringify(goldenPreflight()), {
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url === "/api/private/requests") {
        const envelope = JSON.parse(String(init?.body)) as { client_public_key: string };
        const wire = await encryptedTerminal(envelope.client_public_key);
        return new Response(`data: ${JSON.stringify(wire)}\n\n`, {
          headers: {
            "Content-Type": "text/event-stream",
            "X-Darkbloom-Privacy-Tier": "private-v2-process-bound",
          },
        });
      }
      throw new Error(`unexpected fallback request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    const cb = callbacks().value;

    await streamChat(
      [{ role: "user", content: "PROMPT_MUST_NEVER_REACH_THE_PROXY" }],
      "requested-alias",
      cb,
    );

    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      "/api/private/preflight",
      "/api/private/requests",
    ]);
    const proxyBody = String(fetchMock.mock.calls[1][1]?.body);
    expect(proxyBody).not.toContain("PROMPT_MUST_NEVER_REACH_THE_PROXY");
    expect(JSON.parse(proxyBody)).toMatchObject({
      version: "private_v2",
      lease_id: "lease-vector-1",
      request_id: "request-vector-1",
    });
    expect(cb.onToken).toHaveBeenCalledWith("hello");
    expect(cb.onDone).toHaveBeenCalledWith(
      expect.objectContaining({ privacyTier: "private-v2-process-bound" }),
      expect.any(Object),
    );
    expect(cb.onError).not.toHaveBeenCalled();
  });

  it("surfaces preflight failure and never falls back to /api/chat", async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(
      JSON.stringify({ error: { message: "no certified provider", code: "no_private_provider" } }),
      { status: 503, headers: { "Content-Type": "application/json" } },
    ));
    vi.stubGlobal("fetch", fetchMock);
    const cb = callbacks().value;

    await streamChat(
      [{ role: "user", content: "plaintext sentinel" }],
      "org/model",
      cb,
    );

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/private/preflight");
    expect(fetchMock.mock.calls.some(([url]) => url === "/api/chat")).toBe(false);
    expect(cb.onError).toHaveBeenCalledWith(
      "Private v2 failed (503): no certified provider",
    );
    expect(cb.onDone).not.toHaveBeenCalled();
  });


  it("bounds non-success response text before surfacing the error", async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(
      "x".repeat((64 * 1024) + 1),
      { status: 503, headers: { "Content-Type": "text/plain" } },
    ));
    vi.stubGlobal("fetch", fetchMock);
    const cb = callbacks().value;
    await streamChat([], "org/model", cb);
    expect(cb.onError).toHaveBeenCalledWith(
      "Private v2 failed (503): error response exceeded 64 KiB limit",
    );
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("declares vision and enforces strict self-only routing at preflight", async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(
      JSON.stringify({ error: { message: "self machine unavailable" } }),
      { status: 503, headers: { "Content-Type": "application/json" } },
    ));
    vi.stubGlobal("fetch", fetchMock);
    await streamChat(
      [{
        role: "user",
        content: [{ type: "image_url", image_url: { url: "data:image/png;base64,AQ==" } }],
      }],
      "org/vision-model",
      callbacks().value,
      undefined,
      { selfRoute: true },
    );
    const init = fetchMock.mock.calls[0][1] as RequestInit;
    expect(JSON.parse(String(init.body))).toMatchObject({ requires_vision: true });
    expect(init.headers).toMatchObject({ "X-Darkbloom-Route": "self" });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("expires the browser session when submit rejects authentication", async () => {
    vi.spyOn(Date, "now").mockReturnValue(Date.parse("2030-01-02T03:04:05Z"));
    localStorage.setItem("darkbloom_api_key", "expired");
    const expired = vi.fn();
    window.addEventListener("darkbloom-key-expired", expired);
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(goldenPreflight()), {
        headers: { "Content-Type": "application/json" },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: "expired" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      }));
    vi.stubGlobal("fetch", fetchMock);
    await streamChat(
      [{ role: "user", content: "hello" }],
      "requested-alias",
      callbacks().value,
    );
    expect(localStorage.getItem("darkbloom_api_key")).toBeNull();
    expect(expired).toHaveBeenCalledOnce();
    window.removeEventListener("darkbloom-key-expired", expired);
  });
  it("surfaces invalid preflight cryptography without submitting or retrying legacy", async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(
      JSON.stringify({ version: "private_v2", transcript_digest: "tampered" }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ));
    vi.stubGlobal("fetch", fetchMock);
    const cb = callbacks().value;

    await streamChat([], "org/model", cb);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls.some(([url]) => url === "/api/private/requests")).toBe(false);
    expect(fetchMock.mock.calls.some(([url]) => url === "/api/chat")).toBe(false);
    expect(cb.onError).toHaveBeenCalledWith(
      expect.stringContaining("Private v2 cryptographic validation failed"),
    );
  });
});
