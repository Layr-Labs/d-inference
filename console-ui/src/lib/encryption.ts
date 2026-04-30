// encryption.ts — sender→coordinator request encryption (browser side).
//
// Mirror of coordinator/internal/api/sender_encryption.go. Senders fetch the
// coordinator's long-lived X25519 public key from /v1/encryption-key, NaCl-
// Box-seal each request body to it, and POST as
// Content-Type: application/darkbloom-sealed+json.
//
// Per-request: a fresh ephemeral X25519 keypair gives forward secrecy. The
// coordinator seals its response back using the sender's ephemeral pubkey
// (the sender keeps the private key only for the lifetime of the request).
//
// Optional. The setting lives in localStorage and defaults to off so existing
// SDK / curl examples continue to work unchanged.

import nacl from "tweetnacl";

export const SEALED_CONTENT_TYPE = "application/darkbloom-sealed+json";
export const LEGACY_SEALED_CONTENT_TYPE = "application/eigeninference-sealed+json";
export const ENCRYPTION_FLAG_KEY = "darkbloom_encrypt_to_coordinator";
const COORD_KEY_CACHE_KEY = "darkbloom_coord_enc_key_v2"; // v2: keyed-per-URL
const COORD_KEY_TTL_MS = 60 * 60 * 1000; // 1 hour

export type CoordinatorKey = {
  kid: string;
  publicKey: Uint8Array; // 32 bytes
};

// CachedCoordinatorKey is what we persist in localStorage. The cache is a
// map of coordinator URL → entry, so flipping the configured coordinator
// invalidates the cache implicitly (codex review: a global cache let a fresh
// URL silently encrypt to the previous coordinator's key).
type CachedCoordinatorKey = {
  kid: string;
  publicKeyB64: string;
  fetchedAt: number;
};
type CoordinatorKeyCache = Record<string, CachedCoordinatorKey>;

const DEFAULT_COORDINATOR =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

/** Returns the coordinator URL the user has currently selected. */
function getCoordinatorUrl(): string {
  if (typeof window === "undefined") return DEFAULT_COORDINATOR;
  return (
    window.localStorage.getItem("darkbloom_coordinator_url") || DEFAULT_COORDINATOR
  );
}

function readCache(): CoordinatorKeyCache {
  if (typeof window === "undefined") return {};
  const raw = window.localStorage.getItem(COORD_KEY_CACHE_KEY);
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    return typeof v === "object" && v !== null ? (v as CoordinatorKeyCache) : {};
  } catch {
    return {};
  }
}

function writeCache(cache: CoordinatorKeyCache): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(COORD_KEY_CACHE_KEY, JSON.stringify(cache));
}

/** Returns true if the user has opted into sender→coordinator encryption. */
export function isEncryptionEnabled(): boolean {
  if (typeof window === "undefined") return false;
  return window.localStorage.getItem(ENCRYPTION_FLAG_KEY) === "true";
}

export function setEncryptionEnabled(enabled: boolean): void {
  if (typeof window === "undefined") return;
  if (enabled) {
    window.localStorage.setItem(ENCRYPTION_FLAG_KEY, "true");
  } else {
    window.localStorage.removeItem(ENCRYPTION_FLAG_KEY);
  }
  // Drop any cached key so a flip back-on always re-validates against the
  // coordinator (in case it rotated while we were off).
  window.localStorage.removeItem(COORD_KEY_CACHE_KEY);
}

/**
 * Fetches the coordinator's encryption pubkey from the local /api proxy,
 * forwarding the user-configured coordinator URL so the cache and the fetch
 * always agree on which coordinator we're talking to.
 *
 * Cache: keyed by coordinator URL with a 1h TTL. Switching coordinators in
 * Settings transparently picks up the new pubkey on the next call. The
 * caller should still call clearCoordinatorKeyCache() on a kid_mismatch
 * response to handle in-place key rotation.
 *
 * Throws if the coordinator hasn't enabled the feature (503).
 */
export async function getCoordinatorKey(force = false): Promise<CoordinatorKey> {
  const coordUrl = getCoordinatorUrl();
  if (!force) {
    const cache = readCache();
    const entry = cache[coordUrl];
    if (entry && Date.now() - entry.fetchedAt < COORD_KEY_TTL_MS) {
      return {
        kid: entry.kid,
        publicKey: base64Decode(entry.publicKeyB64),
      };
    }
  }

  const res = await fetch("/api/encryption-key", {
    method: "GET",
    cache: "no-store",
  });
  if (res.status === 503) {
    throw new Error(
      "Sender encryption is not configured on this coordinator — toggle off in Settings, or contact the operator.",
    );
  }
  if (!res.ok) {
    throw new Error(`Encryption key fetch failed: ${res.status}`);
  }
  const body = (await res.json()) as {
    kid: string;
    public_key: string;
    algorithm: string;
  };
  if (body.algorithm !== "x25519-nacl-box") {
    throw new Error(`Unsupported coordinator key algorithm: ${body.algorithm}`);
  }
  const pub = base64Decode(body.public_key);
  if (pub.length !== 32) {
    throw new Error("Coordinator public key is not 32 bytes");
  }

  const cache = readCache();
  cache[coordUrl] = {
    kid: body.kid,
    publicKeyB64: body.public_key,
    fetchedAt: Date.now(),
  };
  writeCache(cache);

  return { kid: body.kid, publicKey: pub };
}

/**
 * Drops every cached coordinator key. Call after a kid_mismatch response or
 * when the user explicitly toggles the feature.
 */
export function clearCoordinatorKeyCache(): void {
  if (typeof window !== "undefined") {
    window.localStorage.removeItem(COORD_KEY_CACHE_KEY);
  }
}

/**
 * SealedRequest holds the on-the-wire JSON envelope plus the ephemeral
 * keypair the caller must keep around to decrypt the coordinator's response.
 */
export type SealedRequest = {
  envelopeJson: string;
  ephemeralPublicKey: Uint8Array;
  ephemeralPrivateKey: Uint8Array;
};

/**
 * Seals a JSON-serializable value for the coordinator. Caller is responsible
 * for setting Content-Type: SEALED_CONTENT_TYPE on the outgoing request.
 */
export function sealRequest<T>(value: T, coordKey: CoordinatorKey): SealedRequest {
  const plaintext = textEncoder.encode(JSON.stringify(value));
  return sealRawRequest(plaintext, coordKey);
}

export function sealRawRequest(plaintext: Uint8Array, coordKey: CoordinatorKey): SealedRequest {
  const ephem = nacl.box.keyPair();
  const nonce = nacl.randomBytes(nacl.box.nonceLength);
  // tweetnacl insists on a plain Uint8Array (not a subarray view or a typed
  // array backed by SharedArrayBuffer); copy into a fresh buffer to be safe.
  const ptCopy = new Uint8Array(plaintext);
  const ct = nacl.box(ptCopy, nonce, coordKey.publicKey, ephem.secretKey);
  // Wire format: 24-byte nonce || ciphertext (matches Go nacl/box).
  const sealed = new Uint8Array(nonce.length + ct.length);
  sealed.set(nonce, 0);
  sealed.set(ct, nonce.length);

  const envelope = {
    kid: coordKey.kid,
    ephemeral_public_key: base64Encode(ephem.publicKey),
    ciphertext: base64Encode(sealed),
  };

  return {
    envelopeJson: JSON.stringify(envelope),
    ephemeralPublicKey: ephem.publicKey,
    ephemeralPrivateKey: ephem.secretKey,
  };
}

/**
 * Unseals a non-streaming sealed response body using the per-request ephemeral
 * private key + the coordinator's pubkey. Returns the decoded plaintext bytes.
 */
export function unsealResponse(
  body: string | Uint8Array,
  ephemeralPrivateKey: Uint8Array,
  coordPub: Uint8Array,
): Uint8Array {
  const text = typeof body === "string" ? body : textDecoder.decode(body);
  const env = JSON.parse(text) as { kid: string; ciphertext: string };
  const sealed = base64Decode(env.ciphertext);
  return openSealed(sealed, ephemeralPrivateKey, coordPub);
}

/**
 * Unseals a single SSE event payload. The payload is the base64 string that
 * appears after `data: ` on the wire (without the prefix). Returns the
 * plaintext event bytes — typically `data: {…}` from the upstream SSE source,
 * which the caller should feed back into a normal SSE parser.
 */
export function unsealSseEvent(
  payloadB64: string,
  ephemeralPrivateKey: Uint8Array,
  coordPub: Uint8Array,
): string {
  const sealed = base64Decode(payloadB64);
  const pt = openSealed(sealed, ephemeralPrivateKey, coordPub);
  return textDecoder.decode(pt);
}

function openSealed(
  sealed: Uint8Array,
  ephemeralPrivateKey: Uint8Array,
  coordPub: Uint8Array,
): Uint8Array {
  if (sealed.length < nacl.box.nonceLength) {
    throw new Error("Sealed payload shorter than the nonce prefix");
  }
  // Copy into fresh Uint8Arrays so tweetnacl's strict type checks don't
  // reject typed-array views.
  const nonce = new Uint8Array(sealed.subarray(0, nacl.box.nonceLength));
  const ct = new Uint8Array(sealed.subarray(nacl.box.nonceLength));
  const pt = nacl.box.open(ct, nonce, coordPub, ephemeralPrivateKey);
  if (!pt) {
    throw new Error("Sealed payload failed to decrypt — wrong key or tampered ciphertext");
  }
  return pt;
}

// --- low-level utilities ----------------------------------------------------

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

function base64Encode(bytes: Uint8Array): string {
  if (typeof window === "undefined") {
    // Node / vitest path
    return Buffer.from(bytes).toString("base64");
  }
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return window.btoa(s);
}

function base64Decode(b64: string): Uint8Array {
  if (typeof window === "undefined") {
    return new Uint8Array(Buffer.from(b64, "base64"));
  }
  const s = window.atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
