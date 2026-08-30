import nacl from "tweetnacl";
import {
  verifyProcessCertificateAttestation,
  type ProcessCertificate,
  type VerifiedProcessDestination,
} from "./private-v2-attestation";
import { requirePinnedPrivateV2Release } from "./private-v2-release-policy";

export type { ProcessCertificate } from "./private-v2-attestation";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });
const REQUEST_INFO = textEncoder.encode("darkbloom/private-v2/request\0");
const RESPONSE_INFO = textEncoder.encode("darkbloom/private-v2/response\0");
const MAX_LEASE_NANOSECONDS = BigInt(60_000_000_000);
const MAX_RESPONSE_CHUNKS = 8192;
const MAX_PRIVATE_PLAINTEXT_BYTES = 16 * 1024 * 1024;
export const PRIVATE_V2_MAX_OUTPUT_TOKENS = 8000;

export type PrivateV2Endpoint =
  | "chat.completions"
  | "responses"
  | "completions"
  | "messages";


export interface PrivateV2Preflight {
  version: "private_v2";
  lease_id: string;
  request_id: string;
  route_id: string;
  model: string;
  endpoint: PrivateV2Endpoint;
  stream: boolean;
  process_public_key: string;
  kdf_salt: string;
  transcript_digest: string;
  process_certificate: ProcessCertificate;
  model_manifest_hash: string;
  release_generation: number;
  model_generation: number;
  expires_at: string;
  requested_max_output_tokens: number;
  requires_vision: boolean;
  route_mode: PrivateV2RouteMode;
  owner_binding: string;
}

export type PrivateV2RouteMode = "public" | "self_route_only" | "prefer_owner";

export interface PrivateV2Transcript {
  deadline: string;
  endpoint: PrivateV2Endpoint;
  lease_id: string;
  model: string;
  model_generation: number;
  model_manifest_hash: string;
  owner_binding: string;
  process_certificate_digest: string;
  release_binary_hash: string;
  release_generation: number;
  request_id: string;
  requested_max_output_tokens: number;
  requires_vision: boolean;
  route_id: string;
  route_mode: PrivateV2RouteMode;
}

export interface PrivateV2RequestEnvelope {
  version: "private_v2";
  lease_id: string;
  request_id: string;
  client_public_key: string;
  nonce: string;
  ciphertext: string;
}

export interface PrivateV2WireChunk {
  type: "private_chunk_v2";
  version: "private_v2";
  request_id: string;
  sequence: number;
  terminal: boolean;
  nonce: string;
  ciphertext: string;
  usage?: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
  failure_code?: string;
  status_code?: number;
}

export interface PrivateV2PlainChunk {
  version: "private_v2";
  request_id: string;
  sequence: number;
  terminal: boolean;
  payload: unknown;
}

export interface SealPrivateV2Options {
  /** Deterministic inputs are accepted only so cross-language vectors can pin the wire contract. */
  ephemeralPrivateKey?: Uint8Array;
  nonce?: Uint8Array;
  now?: number;
}

export interface ExpectedPrivateV2Preflight {
  endpoint: PrivateV2Endpoint;
  stream: boolean;
  requestedMaxOutputTokens: number;
  requiresVision: boolean;
  routeMode: "public" | "self_route_only";
}

export interface ValidatedPrivateV2Preflight {
  preflight: PrivateV2Preflight;
  transcript: PrivateV2Transcript;
  digest: Uint8Array;
  destination: VerifiedProcessDestination;
}

export interface SealedPrivateV2Request {
  envelope: PrivateV2RequestEnvelope;
  session: PrivateV2ResponseSession;
  destination: VerifiedProcessDestination;
  model: string;
  routeMode: "public" | "self_route_only";
}

function bytesBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((total, part) => total + part.length, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

export function encodeBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  const encoded = btoa(binary).replaceAll("+", "-").replaceAll("/", "_");
  if (encoded.endsWith("==")) return encoded.slice(0, -2);
  if (encoded.endsWith("=")) return encoded.slice(0, -1);
  return encoded;
}

export function decodeBase64Url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/u.test(value)) throw new Error("invalid base64url encoding");
  const padding = (4 - (value.length % 4)) % 4;
  const standard = value.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat(padding);
  try {
    const bytes = Uint8Array.from(atob(standard), (char) => char.charCodeAt(0));
    if (encodeBase64Url(bytes) !== value) throw new Error("non-canonical base64url encoding");
    return bytes;
  } catch {
    throw new Error("invalid base64url encoding");
  }
}

function decodeCanonicalBase64(value: string): Uint8Array {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value)) {
    throw new Error("invalid canonical base64 process public key");
  }
  const bytes = Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  if (btoa(binary) !== value) throw new Error("non-canonical process public key");
  return bytes;
}

/** Canonical JSON is UTF-8 JSON with lexicographically sorted object keys and no whitespace. */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("canonical JSON cannot encode a non-finite number");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    const entries = Object.keys(record)
      .sort()
      .map((key) => {
        const item = record[key];
        if (item === undefined) throw new Error(`canonical JSON field ${key} is undefined`);
        return `${JSON.stringify(key)}:${canonicalJson(item)}`;
      });
    return `{${entries.join(",")}}`;
  }
  throw new Error(`canonical JSON cannot encode ${typeof value}`);
}

async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytesBuffer(bytes)));
}

function requireString(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || value.length === 0) throw new Error(`invalid ${field}`);
}

function requireUint64(value: unknown, field: string): asserts value is number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error(`invalid ${field}`);
}

function rfc3339Nanoseconds(value: unknown, field: string): bigint {
  requireString(value, field);
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$/u.exec(value);
  if (!match) throw new Error(`invalid ${field}`);
  const seconds = Date.parse(`${match[1]}Z`);
  if (!Number.isFinite(seconds)) throw new Error(`invalid ${field}`);
  const fraction = (match[2] || "").padEnd(9, "0");
  return BigInt(seconds) * BigInt(1_000_000) + BigInt(fraction || "0");
}

function requireRfc3339(value: unknown, field: string): asserts value is string {
  rfc3339Nanoseconds(value, field);
}

function validateCertificate(value: unknown): asserts value is ProcessCertificate {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid process_certificate");
  }
  const certificate = value as Record<string, unknown>;
  const expectedFields = [
    "backend", "expires_at", "mda_der_chain", "metallib_hash", "mlx_nax", "platform",
    "policy_generation", "process_evidence_signature", "process_evidence_transcript",
    "process_public_key", "provider_version", "release_binary_hash", "runtime_hash",
    "se_public_key", "verified_at", "version",
  ];
  if (JSON.stringify(Object.keys(certificate).sort()) !== JSON.stringify(expectedFields)) {
    throw new Error("process_certificate field mismatch");
  }
  for (const field of [
    "backend",
    "expires_at",
    "metallib_hash",
    "platform",
    "process_evidence_signature",
    "process_evidence_transcript",
    "process_public_key",
    "provider_version",
    "release_binary_hash",
    "runtime_hash",
    "se_public_key",
    "verified_at",
    "version",
  ]) {
    requireString(certificate[field], `process_certificate.${field}`);
  }
  if (certificate.version !== "process_certificate_v1") {
    throw new Error("unsupported process_certificate version");
  }
  if (!Array.isArray(certificate.mda_der_chain) || certificate.mda_der_chain.length === 0) {
    throw new Error("invalid process_certificate.mda_der_chain");
  }
  for (const item of certificate.mda_der_chain) {
    requireString(item, "process_certificate.mda_der_chain");
  }
  if (typeof certificate.mlx_nax !== "boolean") {
    throw new Error("invalid process_certificate.mlx_nax");
  }
  requireUint64(certificate.policy_generation, "process_certificate.policy_generation");
  requireRfc3339(certificate.verified_at, "process_certificate.verified_at");
  requireRfc3339(certificate.expires_at, "process_certificate.expires_at");
}

function certificateContract(certificate: ProcessCertificate): Record<string, unknown> {
  return {
    backend: certificate.backend,
    expires_at: certificate.expires_at,
    mda_der_chain: certificate.mda_der_chain,
    metallib_hash: certificate.metallib_hash,
    mlx_nax: certificate.mlx_nax,
    platform: certificate.platform,
    policy_generation: certificate.policy_generation,
    process_evidence_signature: certificate.process_evidence_signature,
    process_evidence_transcript: certificate.process_evidence_transcript,
    process_public_key: certificate.process_public_key,
    provider_version: certificate.provider_version,
    release_binary_hash: certificate.release_binary_hash,
    runtime_hash: certificate.runtime_hash,
    se_public_key: certificate.se_public_key,
    verified_at: certificate.verified_at,
    version: certificate.version,
  };
}

export async function validatePrivateV2Preflight(
  value: unknown,
  expected: ExpectedPrivateV2Preflight,
  now = Date.now(),
): Promise<ValidatedPrivateV2Preflight> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid preflight response");
  requireUint64(expected.requestedMaxOutputTokens, "requested max output tokens");
  if (
    expected.requestedMaxOutputTokens === 0 ||
    expected.requestedMaxOutputTokens > PRIVATE_V2_MAX_OUTPUT_TOKENS
  ) {
    throw new Error("private_v2 requested max output tokens must be between 1 and 8000");
  }
  const preflight = value as unknown as PrivateV2Preflight;
  if (preflight.version !== "private_v2") throw new Error("provider did not negotiate private_v2");
  if (preflight.endpoint !== expected.endpoint) throw new Error("preflight endpoint mismatch");
  if (preflight.stream !== expected.stream) throw new Error("preflight stream mismatch");
  if (preflight.requested_max_output_tokens !== expected.requestedMaxOutputTokens) {
    throw new Error("preflight max output token mismatch");
  }
  if (preflight.requires_vision !== expected.requiresVision) {
    throw new Error("preflight vision requirement mismatch");
  }
  if (preflight.route_mode === "prefer_owner") {
    throw new Error("private-v2 console does not permit fallback routing");
  }
  if (expected.routeMode === "self_route_only" && preflight.route_mode !== "self_route_only") {
    throw new Error("preflight route mode downgrade");
  }
  if (preflight.route_mode !== "public" && preflight.route_mode !== "self_route_only") {
    throw new Error("invalid preflight route mode");
  }
  if (typeof preflight.owner_binding !== "string") throw new Error("invalid owner_binding");
  if (preflight.route_mode === "public" && preflight.owner_binding !== "") {
    throw new Error("public route cannot carry owner binding");
  }
  if (preflight.route_mode !== "public") {
    const owner = decodeBase64Url(preflight.owner_binding);
    if (owner.length !== 32) throw new Error("invalid owner_binding length");
  }
  for (const field of [
    "lease_id",
    "request_id",
    "route_id",
    "model",
    "process_public_key",
    "kdf_salt",
    "transcript_digest",
    "model_manifest_hash",
  ] as const) {
    requireString(preflight[field], field);
  }
  requireUint64(preflight.release_generation, "release_generation");
  requireUint64(preflight.model_generation, "model_generation");
  requireRfc3339(preflight.expires_at, "expires_at");
  validateCertificate(preflight.process_certificate);
  requireUint64(preflight.requested_max_output_tokens, "requested_max_output_tokens");

  const deadline = rfc3339Nanoseconds(preflight.expires_at, "expires_at");
  const nowNanoseconds = BigInt(Math.trunc(now)) * BigInt(1_000_000);
  if (deadline <= nowNanoseconds) throw new Error("private_v2 lease expired");
  if (deadline - nowNanoseconds > MAX_LEASE_NANOSECONDS) {
    throw new Error("private_v2 lease exceeds 60 seconds");
  }
  if (
    rfc3339Nanoseconds(
      preflight.process_certificate.expires_at,
      "process_certificate.expires_at",
    ) < deadline
  ) {
    throw new Error("process certificate expires before lease");
  }
  if (preflight.process_certificate.process_public_key !== preflight.process_public_key) {
    throw new Error("process public key mismatch");
  }
  const destination = await verifyProcessCertificateAttestation(preflight.process_certificate, now);

  requirePinnedPrivateV2Release(destination.releaseBinaryHash);
  const processPublicKey = decodeCanonicalBase64(preflight.process_public_key);
  if (processPublicKey.length !== nacl.box.publicKeyLength) throw new Error("invalid process public key length");
  const salt = decodeBase64Url(preflight.kdf_salt);
  if (salt.length !== 32) throw new Error("invalid kdf_salt length");
  const advertisedDigest = decodeBase64Url(preflight.transcript_digest);
  if (advertisedDigest.length !== 32) throw new Error("invalid transcript_digest length");

  const certificateDigest = await sha256(textEncoder.encode(canonicalJson(certificateContract(preflight.process_certificate))));
  const transcript: PrivateV2Transcript = {
    deadline: preflight.expires_at,
    endpoint: preflight.endpoint,
    lease_id: preflight.lease_id,
    model: preflight.model,
    model_generation: preflight.model_generation,
    model_manifest_hash: preflight.model_manifest_hash,
    owner_binding: preflight.owner_binding,
    process_certificate_digest: encodeBase64Url(certificateDigest),
    release_binary_hash: preflight.process_certificate.release_binary_hash,
    release_generation: preflight.release_generation,
    request_id: preflight.request_id,
    requested_max_output_tokens: preflight.requested_max_output_tokens,
    requires_vision: preflight.requires_vision,
    route_id: preflight.route_id,
    route_mode: preflight.route_mode,
  };
  const digest = await sha256(textEncoder.encode(canonicalJson(transcript)));
  if (!constantTimeEqual(digest, advertisedDigest)) throw new Error("preflight transcript digest mismatch");
  return { preflight, transcript, digest, destination };
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i];
  return difference === 0;
}

async function deriveAesKey(
  sharedSecret: Uint8Array,
  salt: Uint8Array,
  transcriptDigest: Uint8Array,
  direction: "request" | "response",
): Promise<CryptoKey> {
  const material = await crypto.subtle.importKey(
    "raw",
    bytesBuffer(sharedSecret),
    "HKDF",
    false,
    ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: bytesBuffer(salt),
      info: bytesBuffer(concatBytes(direction === "request" ? REQUEST_INFO : RESPONSE_INFO, transcriptDigest)),
    },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    direction === "request" ? ["encrypt"] : ["decrypt"],
  );
}

function sequenceAad(transcriptDigest: Uint8Array, sequence: number): Uint8Array {
  requireUint64(sequence, "sequence");
  const encoded = new Uint8Array(8);
  const view = new DataView(encoded.buffer);
  const big = BigInt(sequence);
  const uint32Mask = BigInt(0xffffffff);
  view.setUint32(0, Number((big >> BigInt(32)) & uint32Mask));
  view.setUint32(4, Number(big & uint32Mask));
  return concatBytes(transcriptDigest, encoded);
}

export class PrivateV2ResponseSession {
  private responseKey: CryptoKey | null;
  private transcriptDigest: Uint8Array;
  private nextSequence = 0;
  private terminal = false;
  private readonly seenNonces = new Set<string>();

  constructor(responseKey: CryptoKey, transcriptDigest: Uint8Array, readonly requestId: string) {
    this.responseKey = responseKey;
    this.transcriptDigest = transcriptDigest.slice();
  }

  get completed(): boolean {
    return this.terminal;
  }

  async decryptChunk(value: unknown): Promise<PrivateV2PlainChunk> {
    if (this.terminal || !this.responseKey) throw new Error("private_v2 chunk received after terminal");
    if (this.nextSequence >= MAX_RESPONSE_CHUNKS) {
      throw new Error("private_v2 response exceeded chunk capacity");
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid private_v2 chunk");
    const chunk = value as PrivateV2WireChunk;
    if (chunk.type !== "private_chunk_v2" || chunk.version !== "private_v2") {
      throw new Error("invalid private_v2 chunk version");
    }
    if (chunk.request_id !== this.requestId) throw new Error("private_v2 response request id mismatch");
    requireUint64(chunk.sequence, "sequence");
    if (chunk.sequence !== this.nextSequence) throw new Error("private_v2 response sequence mismatch");
    if (typeof chunk.terminal !== "boolean") throw new Error("invalid private_v2 terminal flag");
    const hasTerminalMetadata =
      chunk.usage !== undefined ||
      chunk.failure_code !== undefined ||
      chunk.status_code !== undefined;
    if (hasTerminalMetadata && !chunk.terminal) {
      throw new Error("private_v2 metadata is only valid on terminal chunks");
    }
    if (chunk.usage !== undefined) {
      requireUint64(chunk.usage.prompt_tokens, "usage.prompt_tokens");
      requireUint64(chunk.usage.completion_tokens, "usage.completion_tokens");
      requireUint64(chunk.usage.total_tokens, "usage.total_tokens");
    }
    if (
      chunk.failure_code !== undefined &&
      (typeof chunk.failure_code !== "string" || chunk.failure_code.length === 0)
    ) {
      throw new Error("invalid private_v2 failure code");
    }
    if (
      chunk.status_code !== undefined &&
      (!Number.isInteger(chunk.status_code) || chunk.status_code < 100 || chunk.status_code > 599)
    ) {
      throw new Error("invalid private_v2 status code");
    }
    if (this.seenNonces.has(chunk.nonce)) throw new Error("private_v2 response nonce reuse");
    const nonce = decodeBase64Url(chunk.nonce);
    if (nonce.length !== 12) throw new Error("invalid private_v2 response nonce");
    const ciphertext = decodeBase64Url(chunk.ciphertext);
    if (ciphertext.length < 16) throw new Error("invalid private_v2 response ciphertext");

    let plaintextBytes: Uint8Array;
    try {
      plaintextBytes = new Uint8Array(await crypto.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: bytesBuffer(nonce),
          additionalData: bytesBuffer(sequenceAad(this.transcriptDigest, chunk.sequence)),
          tagLength: 128,
        },
        this.responseKey,
        bytesBuffer(ciphertext),
      ));
    } catch {
      throw new Error("private_v2 response authentication failed");
    }

    let plaintext: PrivateV2PlainChunk;
    try {
      plaintext = JSON.parse(textDecoder.decode(plaintextBytes)) as PrivateV2PlainChunk;
    } catch {
      plaintextBytes.fill(0);
      throw new Error("invalid private_v2 response plaintext");
    }
    plaintextBytes.fill(0);
    if (
      plaintext.version !== "private_v2" ||
      plaintext.request_id !== chunk.request_id ||
      plaintext.sequence !== chunk.sequence ||
      plaintext.terminal !== chunk.terminal
    ) {
      throw new Error("private_v2 response transcript mismatch");
    }
    this.seenNonces.add(chunk.nonce);

    this.nextSequence += 1;
    if (plaintext.terminal) {
      this.terminal = true;
      this.disposeKeys();
    }
    return plaintext;
  }

  dispose(): void {
    this.terminal = true;
    this.disposeKeys();
  }

  private disposeKeys(): void {
    this.responseKey = null;
    this.transcriptDigest.fill(0);
    this.seenNonces.clear();
  }
}

export async function sealPrivateV2Request(
  preflightValue: unknown,
  expected: ExpectedPrivateV2Preflight,
  body: unknown,
  options: SealPrivateV2Options = {},
): Promise<SealedPrivateV2Request> {
  const { preflight, transcript, digest, destination } = await validatePrivateV2Preflight(
    preflightValue,
    expected,
    options.now,
  );
  const processPublicKey = decodeCanonicalBase64(preflight.process_public_key);
  const privateKey = options.ephemeralPrivateKey?.slice() ?? nacl.box.keyPair().secretKey;
  if (privateKey.length !== nacl.box.secretKeyLength) throw new Error("invalid ephemeral private key length");
  const clientPublicKey = nacl.scalarMult.base(privateKey);
  const sharedSecret = nacl.scalarMult(privateKey, processPublicKey);
  privateKey.fill(0);
  if (sharedSecret.every((byte) => byte === 0)) {
    sharedSecret.fill(0);
    digest.fill(0);
    throw new Error("invalid X25519 shared secret");
  }

  let requestKey: CryptoKey;
  let responseKey: CryptoKey;
  try {
    [requestKey, responseKey] = await Promise.all([
      deriveAesKey(sharedSecret, decodeBase64Url(preflight.kdf_salt), digest, "request"),
      deriveAesKey(sharedSecret, decodeBase64Url(preflight.kdf_salt), digest, "response"),
    ]);
  } finally {
    sharedSecret.fill(0);
  }

  const nonce = options.nonce?.slice() ?? crypto.getRandomValues(new Uint8Array(12));
  if (nonce.length !== 12) {
    digest.fill(0);
    throw new Error("invalid request nonce length");
  }
  const boundBody = body && typeof body === "object" && !Array.isArray(body) && "model" in body
    ? { ...body, model: preflight.model }
    : body;
  const plaintext = textEncoder.encode(canonicalJson({ ...transcript, body: boundBody }));
  if (plaintext.length > MAX_PRIVATE_PLAINTEXT_BYTES) {
    plaintext.fill(0);
    digest.fill(0);
    throw new Error("private_v2 request exceeds encrypted payload capacity");
  }
  let ciphertext: Uint8Array;
  try {
    ciphertext = new Uint8Array(await crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv: bytesBuffer(nonce),
        additionalData: bytesBuffer(digest),
        tagLength: 128,
      },
      requestKey,
      bytesBuffer(plaintext),
    ));
  } finally {
    plaintext.fill(0);
  }

  const session = new PrivateV2ResponseSession(responseKey, digest, preflight.request_id);
  digest.fill(0);
  return {
    envelope: {
      version: "private_v2",
      lease_id: preflight.lease_id,
      request_id: preflight.request_id,
      client_public_key: encodeBase64Url(clientPublicKey),
      nonce: encodeBase64Url(nonce),
      ciphertext: encodeBase64Url(ciphertext),
    },
    session,
    destination,
    model: preflight.model,
    routeMode: preflight.route_mode,
  };
}
