import "reflect-metadata";
import {
  BasicConstraintsExtension,
  KeyUsageFlags,
  KeyUsagesExtension,
  X509Certificate,
} from "@peculiar/x509";

const textEncoder = new TextEncoder();
const ALLOWED_CRITICAL_EXTENSIONS: Record<string, true> = {
  "2.5.29.14": true,
  "2.5.29.15": true,
  "2.5.29.19": true,
  "2.5.29.32": true,
  "2.5.29.35": true,
  "2.5.29.37": true,
};
const textDecoder = new TextDecoder("utf-8", { fatal: true });
const FRESHNESS_OID = "1.2.840.113635.100.8.11.1";
const SERIAL_OID = "1.2.840.113635.100.8.9.1";
const PROCESS_EVIDENCE_DOMAIN = "darkbloom.process_evidence";
const PROCESS_EVIDENCE_VERSION = "process_evidence_v1";
const APPLE_ENTERPRISE_ATTESTATION_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICJDCCAamgAwIBAgIUQsDCuyxyfFxeq/bxpm8frF15hzcwCgYIKoZIzj0EAwMw
UTEtMCsGA1UEAwwkQXBwbGUgRW50ZXJwcmlzZSBBdHRlc3RhdGlvbiBSb290IENB
MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzAeFw0yMjAyMTYxOTAx
MjRaFw00NzAyMjAwMDAwMDBaMFExLTArBgNVBAMMJEFwcGxlIEVudGVycHJpc2Ug
QXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UE
BhMCVVMwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAT6Jigq+Ps9Q4CoT8t8q+UnOe2p
oT9nRaUfGhBTbgvqSGXPjVkbYlIWYO+1zPk2Sz9hQ5ozzmLrPmTBgEWRcHjA2/y7
7GEicps9wn2tj+G89l3INNDKETdxSPPIZpPj8VmjQjBAMA8GA1UdEwEB/wQFMAMB
Af8wHQYDVR0OBBYEFPNqTQGd8muBpV5du+UIbVbi+d66MA4GA1UdDwEB/wQEAwIB
BjAKBggqhkjOPQQDAwNpADBmAjEA1xpWmTLSpr1VH4f8Ypk8f3jMUKYz4QPG8mL5
8m9sX/b2+eXpTv2pH4RZgJjucnbcAjEA4ZSB6S45FlPuS/u4pTnzoz632rA+xW/T
ZwFEh9bhKjJ+5VQ9/Do1os0u3LEkgN/r
-----END CERTIFICATE-----`;

export interface ProcessCertificate {
  backend: string;
  expires_at: string;
  mda_der_chain: string[];
  metallib_hash: string;
  mlx_nax: boolean;
  platform: string;
  policy_generation: number;
  process_evidence_signature: string;
  process_evidence_transcript: string;
  process_public_key: string;
  provider_version: string;
  release_binary_hash: string;
  runtime_hash: string;
  se_public_key: string;
  verified_at: string;
  version: "process_certificate_v1";
}

export interface VerifiedProcessDestination {
  backend: string;
  platform: string;
  providerVersion: string;
  processPublicKey: string;
  releaseBinaryHash: string;
  sePublicKey: string;
  verifiedAt: string;
  expiresAt: string;
}

interface ProcessEvidenceV1 {
  binary_hash: string;
  challenge_generation: string;
  coordinator_nonce: string;
  coordinator_session_id: string;
  coordinator_timestamp: string;
  domain: "darkbloom.process_evidence";
  evidence_expires_at: string;
  metallib_hash: string;
  process_public_key: string;
  provider_backend: string;
  provider_platform: string;
  provider_version: string;
  runtime_hash: string;
  se_public_key: string;
  secure_boot_enabled: boolean;
  serial_number: string;
  sip_enabled: boolean;
  version: "process_evidence_v1";
}

function bytesBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index];
  return difference === 0;
}

function binaryString(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return binary;
}

function standardBase64(value: string, field: string): Uint8Array {
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  const contentLength = value.length - padding;
  if (
    value.length === 0 ||
    value.length % 4 !== 0 ||
    value.slice(0, contentLength).includes("=")
  ) {
    throw new Error(`invalid ${field}`);
  }
  for (let index = 0; index < contentLength; index++) {
    const code = value.charCodeAt(index);
    const valid = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) || code === 43 || code === 47;
    if (!valid) throw new Error(`invalid ${field}`);
  }
  const bytes = Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
  if (btoa(binaryString(bytes)) !== value) throw new Error(`non-canonical ${field}`);
  return bytes;
}

function base64Url(value: string, field: string, maxBytes: number): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/u.test(value)) throw new Error(`invalid ${field}`);
  const padding = (4 - (value.length % 4)) % 4;
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(
      atob(value.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat(padding)),
      (character) => character.charCodeAt(0),
    );
  } catch {
    throw new Error(`invalid ${field}`);
  }
  if (bytes.length > maxBytes) throw new Error(`${field} exceeds byte limit`);
  const encoded = btoa(binaryString(bytes)).replaceAll("+", "-").replaceAll("/", "_");
  const canonical = encoded.endsWith("==")
    ? encoded.slice(0, -2)
    : encoded.endsWith("=") ? encoded.slice(0, -1) : encoded;
  if (canonical !== value) throw new Error(`non-canonical ${field}`);
  return bytes;
}

function readDerLength(bytes: Uint8Array, offset: number): { length: number; offset: number } {
  const first = bytes[offset];
  if (first === undefined) throw new Error("truncated DER value");
  if ((first & 0x80) === 0) return { length: first, offset: offset + 1 };
  const count = first & 0x7f;
  if (count === 0 || count > 4 || offset + count >= bytes.length) {
    throw new Error("invalid DER length");
  }
  if (bytes[offset + 1] === 0) throw new Error("non-canonical DER length");
  let length = 0;
  for (let index = 1; index <= count; index++) length = (length * 256) + bytes[offset + index];
  if (length < 128) throw new Error("non-canonical DER length");
  return { length, offset: offset + count + 1 };
}

function unwrapDerValue(bytes: Uint8Array): Uint8Array {
  if (bytes.length < 2) return bytes;
  try {
    const parsed = readDerLength(bytes, 1);
    const end = parsed.offset + parsed.length;
    if (end !== bytes.length) return bytes;
    return bytes.subarray(parsed.offset, end);
  } catch {
    return bytes;
  }
}


function timestampMillis(value: string): number {
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$/u.exec(value);
  if (!match) return Number.NaN;
  const milliseconds = (match[2] || "").slice(0, 3).padEnd(3, "0");
  return Date.parse(`${match[1]}.${milliseconds}Z`);
}
function certificateIsCurrent(certificate: X509Certificate, now: Date): boolean {
  return certificate.notBefore.getTime() <= now.getTime() && now.getTime() < certificate.notAfter.getTime();
}

function requireCertificateConstraints(
  certificate: X509Certificate,
  caCertificatesBelow: number,
): void {
  for (const extension of certificate.extensions) {
    if (extension.critical && !ALLOWED_CRITICAL_EXTENSIONS[extension.type]) {
      throw new Error(`unsupported critical MDA extension ${extension.type}`);
    }
  }
  const constraints = certificate.getExtension(BasicConstraintsExtension);
  if (!constraints?.ca) throw new Error("MDA intermediate is not a CA");
  if (
    constraints.pathLength !== undefined &&
    caCertificatesBelow > constraints.pathLength
  ) {
    throw new Error("MDA path length constraint exceeded");
  }
  const usages = certificate.getExtension(KeyUsagesExtension);
  if (usages && (usages.usages & KeyUsageFlags.keyCertSign) === 0) {
    throw new Error("MDA intermediate cannot sign certificates");
  }
}

async function verifyMdaChain(
  chainValues: string[],
  now: Date,
  root: X509Certificate,
): Promise<X509Certificate> {
  if (chainValues.length === 0 || chainValues.length > 6) throw new Error("invalid MDA chain length");
  const certificates = chainValues.map(
    (value, index) => new X509Certificate(bytesBuffer(base64Url(value, `mda_der_chain[${index}]`, 32 * 1024))),
  );
  const last = certificates.at(-1)!;
  if (equalBytes(new Uint8Array(last.rawData), new Uint8Array(root.rawData))) certificates.pop();
  const leaf = certificates[0];
  if (!leaf || !certificateIsCurrent(leaf, now)) throw new Error("MDA leaf certificate is not current");
  for (const extension of leaf.extensions) {
    if (extension.critical && !ALLOWED_CRITICAL_EXTENSIONS[extension.type]) {
      throw new Error(`unsupported critical MDA extension ${extension.type}`);
    }
  }
  const leafConstraints = leaf.getExtension(BasicConstraintsExtension);
  if (leafConstraints?.ca) throw new Error("MDA leaf certificate cannot be a CA");

  let child = leaf;
  const issuers = [...certificates.slice(1), root];
  for (let index = 0; index < issuers.length; index++) {
    const issuer = issuers[index];
    if (!certificateIsCurrent(issuer, now)) throw new Error("MDA issuer certificate is not current");
    requireCertificateConstraints(issuer, index);
    if (child.issuer !== issuer.subject) throw new Error("MDA certificate issuer mismatch");
    if (!await child.verify({ date: now, publicKey: issuer.publicKey, signatureOnly: true })) {
      throw new Error("MDA certificate signature verification failed");
    }
    child = issuer;
  }
  return leaf;
}

function exactEvidence(value: unknown): ProcessEvidenceV1 {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid process evidence transcript");
  }
  const evidence = value as Record<string, unknown>;
  const expectedKeys = [
    "binary_hash", "challenge_generation", "coordinator_nonce", "coordinator_session_id",
    "coordinator_timestamp", "domain", "evidence_expires_at", "metallib_hash",
    "process_public_key", "provider_backend", "provider_platform", "provider_version",
    "runtime_hash", "se_public_key", "secure_boot_enabled", "serial_number", "sip_enabled",
    "version",
  ];
  if (JSON.stringify(Object.keys(evidence).sort()) !== JSON.stringify(expectedKeys)) {
    throw new Error("process evidence field mismatch");
  }
  for (const key of expectedKeys.filter((key) => !key.endsWith("_enabled"))) {
    if (typeof evidence[key] !== "string") throw new Error(`invalid process evidence ${key}`);
  }
  for (const key of [
    "binary_hash", "challenge_generation", "coordinator_nonce", "coordinator_session_id",
    "coordinator_timestamp", "evidence_expires_at", "process_public_key", "provider_backend",
    "provider_platform", "provider_version", "se_public_key", "serial_number",
  ]) {
    if ((evidence[key] as string).length === 0) {
      throw new Error(`empty process evidence ${key}`);
    }
  }
  if (evidence.domain !== PROCESS_EVIDENCE_DOMAIN || evidence.version !== PROCESS_EVIDENCE_VERSION) {
    throw new Error("unsupported process evidence contract");
  }
  if (evidence.sip_enabled !== true || evidence.secure_boot_enabled !== true) {
    throw new Error("process evidence security posture is not certified");
  }
  return evidence as unknown as ProcessEvidenceV1;
}

function canonicalEvidence(evidence: ProcessEvidenceV1): string {
  return JSON.stringify({
    binary_hash: evidence.binary_hash,
    challenge_generation: evidence.challenge_generation,
    coordinator_nonce: evidence.coordinator_nonce,
    coordinator_session_id: evidence.coordinator_session_id,
    coordinator_timestamp: evidence.coordinator_timestamp,
    domain: evidence.domain,
    evidence_expires_at: evidence.evidence_expires_at,
    metallib_hash: evidence.metallib_hash,
    process_public_key: evidence.process_public_key,
    provider_backend: evidence.provider_backend,
    provider_platform: evidence.provider_platform,
    provider_version: evidence.provider_version,
    runtime_hash: evidence.runtime_hash,
    se_public_key: evidence.se_public_key,
    secure_boot_enabled: evidence.secure_boot_enabled,
    serial_number: evidence.serial_number,
    sip_enabled: evidence.sip_enabled,
    version: evidence.version,
  });
}

function p256RawKey(value: string): Uint8Array {
  const decoded = standardBase64(value, "se_public_key");
  if (decoded.length === 65 && decoded[0] === 4) return decoded;
  if (decoded.length !== 64) throw new Error("invalid se_public_key length");
  const raw = new Uint8Array(65);
  raw[0] = 4;
  raw.set(decoded, 1);
  return raw;
}

function derInteger(bytes: Uint8Array, offset: number): { value: Uint8Array; offset: number } {
  if (bytes[offset] !== 0x02) throw new Error("invalid ECDSA DER integer");
  const parsed = readDerLength(bytes, offset + 1);
  const end = parsed.offset + parsed.length;
  if (parsed.length === 0 || end > bytes.length) throw new Error("invalid ECDSA DER integer");
  let value = bytes.subarray(parsed.offset, end);
  if ((value[0] & 0x80) !== 0) throw new Error("negative ECDSA DER integer");
  if (value[0] === 0) {
    if (value.length === 1 || (value[1] & 0x80) === 0) {
      throw new Error("non-canonical ECDSA DER integer");
    }
    value = value.subarray(1);
  }
  if (value.length > 32) throw new Error("invalid ECDSA P-256 integer");
  const padded = new Uint8Array(32);
  padded.set(value, 32 - value.length);
  return { value: padded, offset: end };
}

function derP256Signature(bytes: Uint8Array): Uint8Array {
  if (bytes[0] !== 0x30) throw new Error("invalid ECDSA DER signature");
  const sequence = readDerLength(bytes, 1);
  if (sequence.offset + sequence.length !== bytes.length) throw new Error("invalid ECDSA DER signature");
  const r = derInteger(bytes, sequence.offset);
  const s = derInteger(bytes, r.offset);
  if (s.offset !== bytes.length) throw new Error("invalid ECDSA DER signature");
  const raw = new Uint8Array(64);
  raw.set(r.value);
  raw.set(s.value, 32);
  return raw;
}

function processFieldsMatch(certificate: ProcessCertificate, evidence: ProcessEvidenceV1): boolean {
  return evidence.process_public_key === certificate.process_public_key &&
    evidence.binary_hash === certificate.release_binary_hash &&
    evidence.provider_version === certificate.provider_version &&
    evidence.provider_platform === certificate.platform &&
    evidence.provider_backend === certificate.backend &&
    evidence.runtime_hash === certificate.runtime_hash &&
    evidence.metallib_hash === certificate.metallib_hash &&
    evidence.se_public_key === certificate.se_public_key &&
    evidence.evidence_expires_at === certificate.expires_at;
}

async function verifyProcessCertificateAgainstRoot(
  certificate: ProcessCertificate,
  root: X509Certificate,
  now: number,
): Promise<VerifiedProcessDestination> {
  if (certificate.version !== "process_certificate_v1") {
    throw new Error("unsupported process certificate version");
  }
  let leaf: X509Certificate;
  try {
    leaf = await verifyMdaChain(certificate.mda_der_chain, new Date(now), root);
  } catch {
    // Raw MDA bytes and device identifiers must never reach UI or telemetry.
    throw new Error("Apple MDA certificate verification failed");
  }
  const evidenceBytes = base64Url(
    certificate.process_evidence_transcript,
    "process_evidence_transcript",
    64 * 1024,
  );
  const evidenceText = textDecoder.decode(evidenceBytes);
  let parsed: unknown;
  try {
    parsed = JSON.parse(evidenceText);
  } catch {
    throw new Error("invalid process evidence JSON");
  }
  const evidence = exactEvidence(parsed);
  if (canonicalEvidence(evidence) !== evidenceText) throw new Error("non-canonical process evidence transcript");
  if (!processFieldsMatch(certificate, evidence)) throw new Error("process evidence certificate mismatch");
  const expiresAt = timestampMillis(evidence.evidence_expires_at);
  const verifiedAt = timestampMillis(certificate.verified_at);
  const coordinatorTimestamp = timestampMillis(evidence.coordinator_timestamp);
  if (!Number.isFinite(expiresAt) || expiresAt <= now || !Number.isFinite(verifiedAt) || verifiedAt > now) {
    throw new Error("process evidence is not current");
  }
  if (!Number.isFinite(coordinatorTimestamp) || coordinatorTimestamp > verifiedAt) {
    throw new Error("process evidence timestamp mismatch");
  }

  const freshness = leaf.getExtension(FRESHNESS_OID);
  if (!freshness) throw new Error("MDA freshness binding is missing");
  const expectedFreshness = new Uint8Array(await crypto.subtle.digest(
    "SHA-256",
    bytesBuffer(textEncoder.encode(certificate.se_public_key)),
  ));
  if (!equalBytes(unwrapDerValue(new Uint8Array(freshness.value)), expectedFreshness)) {
    throw new Error("MDA freshness does not bind the Secure Enclave key");
  }
  const serial = leaf.getExtension(SERIAL_OID);
  const attestedSerial = serial
    ? textDecoder.decode(unwrapDerValue(new Uint8Array(serial.value)))
    : leaf.subjectName.getField("2.5.4.5")[0] || "";
  if (!attestedSerial || attestedSerial !== evidence.serial_number) {
    throw new Error("MDA serial does not match process evidence");
  }

  const seKey = await crypto.subtle.importKey(
    "raw",
    bytesBuffer(p256RawKey(certificate.se_public_key)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const signature = derP256Signature(base64Url(
    certificate.process_evidence_signature,
    "process_evidence_signature",
    256,
  ));
  if (!await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    seKey,
    bytesBuffer(signature),
    bytesBuffer(evidenceBytes),
  )) {
    throw new Error("process evidence signature verification failed");
  }

  const processKey = standardBase64(certificate.process_public_key, "process_public_key");
  if (processKey.length !== 32) throw new Error("invalid process_public_key length");
  return {
    backend: certificate.backend,
    platform: certificate.platform,
    providerVersion: certificate.provider_version,
    processPublicKey: certificate.process_public_key,
    releaseBinaryHash: certificate.release_binary_hash,
    sePublicKey: certificate.se_public_key,
    verifiedAt: certificate.verified_at,
    expiresAt: certificate.expires_at,
  };
}

export function verifyProcessCertificateAttestation(
  certificate: ProcessCertificate,
  now = Date.now(),
): Promise<VerifiedProcessDestination> {
  return verifyProcessCertificateAgainstRoot(
    certificate,
    new X509Certificate(APPLE_ENTERPRISE_ATTESTATION_ROOT_PEM),
    now,
  );
}

/** Explicit trust-anchor seam for generated-chain contract tests. Production never calls this. */
export function verifyProcessCertificateAttestationAgainstRoot(
  certificate: ProcessCertificate,
  trustedRootDer: BufferSource,
  now: number,
): Promise<VerifiedProcessDestination> {
  return verifyProcessCertificateAgainstRoot(
    certificate,
    new X509Certificate(trustedRootDer),
    now,
  );
}
