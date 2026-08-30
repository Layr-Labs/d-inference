import { describe, expect, it, vi } from "vitest";

import vector from "./fixtures/private-v2-golden.json";
import {
  canonicalJson,
  decodeBase64Url,
  encodeBase64Url,
  PRIVATE_V2_MAX_OUTPUT_TOKENS,
  sealPrivateV2Request,
  validatePrivateV2Preflight,
  type PrivateV2Preflight,
  type PrivateV2WireChunk,
} from "@/lib/private-v2";
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

const NOW = Date.parse("2030-01-02T03:04:05Z");
const expected = {
  endpoint: "chat.completions" as const,
  stream: true,
  requestedMaxOutputTokens: 4096,
  requiresVision: false,
  routeMode: "public" as const,
};

function preflight(): PrivateV2Preflight {
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
    process_certificate: vector.process_certificate as PrivateV2Preflight["process_certificate"],
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

function wireChunk(overrides: Partial<PrivateV2WireChunk> = {}): PrivateV2WireChunk {
  return {
    type: "private_chunk_v2",
    version: "private_v2",
    request_id: "request-vector-1",
    sequence: 0,
    terminal: true,
    nonce: vector.response_nonce,
    ciphertext: vector.response_ciphertext,
    ...overrides,
  };
}

async function coordinatorForcedSelfPreflight(): Promise<PrivateV2Preflight> {
  const ownerBinding = encodeBase64Url(new Uint8Array(32));
  const transcript = {
    ...(JSON.parse(vector.transcript_json) as Record<string, unknown>),
    owner_binding: ownerBinding,
    route_mode: "self_route_only",
  };
  const bytes = new TextEncoder().encode(canonicalJson(transcript));
  const digest = new Uint8Array(await crypto.subtle.digest(
    "SHA-256",
    bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
  ));
  return {
    ...preflight(),
    owner_binding: ownerBinding,
    route_mode: "self_route_only",
    transcript_digest: encodeBase64Url(digest),
  };
}

async function sealed() {
  return sealPrivateV2Request(preflight(), expected, vector.request_body, {
    now: NOW,
    ephemeralPrivateKey: decodeBase64Url(vector.client_private_key),
    nonce: decodeBase64Url(vector.request_nonce),
  });
}

describe("private-v2 browser cryptography", () => {
  it("matches the shared X25519/HKDF-SHA256/AES-GCM golden vector byte-for-byte", async () => {
    const validated = await validatePrivateV2Preflight(preflight(), expected, NOW);
    expect(canonicalJson(validated.transcript)).toBe(vector.transcript_json);
    expect(vector.transcript_digest).toBe("Rq0y9i3k53SOLHY68koVgt2xqiwz3Ea8VOtZDNzRV20");

    const result = await sealed();
    expect(result.envelope).toEqual({
      version: "private_v2",
      lease_id: "lease-vector-1",
      request_id: "request-vector-1",
      client_public_key: vector.client_public_key,
      nonce: vector.request_nonce,
      ciphertext: vector.request_ciphertext,
    });
    expect(JSON.stringify(result.envelope)).not.toContain("PROMPT_MUST_NEVER_REACH_THE_PROXY");

    const chunk = await result.session.decryptChunk(wireChunk());
    expect(canonicalJson(chunk)).toBe(vector.response_plaintext);
    expect(chunk.payload).toEqual({ choices: [{ delta: { content: "hello" } }] });
    expect(result.session.completed).toBe(true);
  });

  it("rejects transcript and generation drift before encrypting", async () => {
    const changedModel = { ...preflight(), model: "org/substituted-model" };
    await expect(validatePrivateV2Preflight(changedModel, expected, NOW)).rejects.toThrow(
      "transcript digest mismatch",
    );

    const changedRelease = { ...preflight(), release_generation: 10 };
    await expect(validatePrivateV2Preflight(changedRelease, expected, NOW)).rejects.toThrow(
      "transcript digest mismatch",
    );

    const changedModelGeneration = { ...preflight(), model_generation: 10 };
    await expect(validatePrivateV2Preflight(changedModelGeneration, expected, NOW)).rejects.toThrow(
      "transcript digest mismatch",
    );
  });


  it("accepts a coordinator-forced stricter self route but never a downgrade", async () => {
    const forcedSelf = await coordinatorForcedSelfPreflight();
    await expect(validatePrivateV2Preflight(forcedSelf, expected, NOW)).resolves.toMatchObject({
      transcript: { route_mode: "self_route_only", owner_binding: forcedSelf.owner_binding },
    });

    await expect(validatePrivateV2Preflight(
      preflight(),
      { ...expected, routeMode: "self_route_only" },
      NOW,
    )).rejects.toThrow("route mode downgrade");
  });

  it("accepts the shared 8000-token ceiling and rejects values above it", async () => {
    const transcript = {
      ...(JSON.parse(vector.transcript_json) as Record<string, unknown>),
      requested_max_output_tokens: PRIVATE_V2_MAX_OUTPUT_TOKENS,
    };
    const bytes = new TextEncoder().encode(canonicalJson(transcript));
    const digest = new Uint8Array(await crypto.subtle.digest(
      "SHA-256",
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
    ));
    const atLimit = {
      ...preflight(),
      requested_max_output_tokens: PRIVATE_V2_MAX_OUTPUT_TOKENS,
      transcript_digest: encodeBase64Url(digest),
    };
    await expect(validatePrivateV2Preflight(
      atLimit,
      { ...expected, requestedMaxOutputTokens: PRIVATE_V2_MAX_OUTPUT_TOKENS },
      NOW,
    )).resolves.toMatchObject({
      transcript: { requested_max_output_tokens: PRIVATE_V2_MAX_OUTPUT_TOKENS },
    });
    await expect(validatePrivateV2Preflight(
      atLimit,
      { ...expected, requestedMaxOutputTokens: PRIVATE_V2_MAX_OUTPUT_TOKENS + 1 },
      NOW,
    )).rejects.toThrow("between 1 and 8000");
  });
  it("rejects a lease longer than 60 seconds and an expired lease", async () => {
    await expect(validatePrivateV2Preflight(
      { ...preflight(), expires_at: "2030-01-02T03:05:06Z" },
      expected,
      NOW,
    )).rejects.toThrow("exceeds 60 seconds");
    await expect(validatePrivateV2Preflight(
      { ...preflight(), expires_at: "2030-01-02T03:04:04Z" },
      expected,
      NOW,
    )).rejects.toThrow("lease expired");
  });

  it("fails closed on AES tag tampering", async () => {
    const result = await sealed();
    const first = vector.response_ciphertext[0] === "A" ? "B" : "A";
    await expect(result.session.decryptChunk(wireChunk({
      ciphertext: first + vector.response_ciphertext.slice(1),
    }))).rejects.toThrow("response authentication failed");
    result.session.dispose();
  });

  it("rejects skipped, replayed, and post-terminal sequences", async () => {
    const skipped = await sealed();
    await expect(skipped.session.decryptChunk(wireChunk({ sequence: 1 }))).rejects.toThrow(
      "sequence mismatch",
    );
    skipped.session.dispose();

    const replayed = await sealed();
    await replayed.session.decryptChunk(wireChunk());
    await expect(replayed.session.decryptChunk(wireChunk())).rejects.toThrow("after terminal");
  });

  it("rejects request-id and authenticated-terminal mismatches", async () => {
    const wrongRequest = await sealed();
    await expect(wrongRequest.session.decryptChunk(wireChunk({ request_id: "request-other" })))
      .rejects.toThrow("request id mismatch");
    wrongRequest.session.dispose();

    const wrongTerminal = await sealed();
    await expect(wrongTerminal.session.decryptChunk(wireChunk({ terminal: false })))
      .rejects.toThrow("response transcript mismatch");
    wrongTerminal.session.dispose();
  });

  it("accepts well-formed terminal usage and rejects unauthenticated usage drift", async () => {
    const valid = await sealed();
    await expect(valid.session.decryptChunk(wireChunk({
      usage: { prompt_tokens: 12, completion_tokens: 1, total_tokens: 13 },
    }))).resolves.toMatchObject({ terminal: true });

    const nonterminal = await sealed();
    await expect(nonterminal.session.decryptChunk(wireChunk({
      terminal: false,
      usage: { prompt_tokens: 12, completion_tokens: 1, total_tokens: 13 },
    }))).rejects.toThrow("only valid on terminal chunks");
    nonterminal.session.dispose();

    const invalid = await sealed();
    await expect(invalid.session.decryptChunk(wireChunk({
      usage: { prompt_tokens: -1, completion_tokens: 1, total_tokens: 0 },
    }))).rejects.toThrow("usage.prompt_tokens");
    invalid.session.dispose();
  });
});
