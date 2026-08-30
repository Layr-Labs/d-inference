import "reflect-metadata";
import {
  BasicConstraintsExtension,
  Extension,
  KeyUsageFlags,
  KeyUsagesExtension,
  X509CertificateGenerator,
} from "@peculiar/x509";
import { describe, expect, it } from "vitest";
import {
  verifyProcessCertificateAttestation,
  verifyProcessCertificateAttestationAgainstRoot,
  type ProcessCertificate,
} from "@/lib/private-v2-attestation";

const NOW = Date.parse("2030-01-02T03:04:05Z");
const FRESHNESS_OID = "1.2.840.113635.100.8.11.1";
const SERIAL_OID = "1.2.840.113635.100.8.9.1";

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function standardBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64Url(bytes: Uint8Array): string {
  const encoded = standardBase64(bytes).replaceAll("+", "-").replaceAll("/", "_");
  if (encoded.endsWith("==")) return encoded.slice(0, -2);
  if (encoded.endsWith("=")) return encoded.slice(0, -1);
  return encoded;
}

function derValue(tag: number, value: Uint8Array): Uint8Array {
  if (value.length >= 128) throw new Error("test DER value too long");
  return new Uint8Array([tag, value.length, ...value]);
}

function derSignature(raw: Uint8Array): Uint8Array {
  const integer = (value: Uint8Array) => {
    let start = 0;
    while (start < value.length - 1 && value[start] === 0) start++;
    let body = value.subarray(start);
    if ((body[0] & 0x80) !== 0) body = new Uint8Array([0, ...body]);
    return derValue(0x02, body);
  };
  const r = integer(raw.subarray(0, 32));
  const s = integer(raw.subarray(32));
  return derValue(0x30, new Uint8Array([...r, ...s]));
}

function canonicalEvidence(fields: {
  processKey: string;
  seKey: string;
  serial: string;
}): string {
  return JSON.stringify({
    binary_hash: "11".repeat(32),
    challenge_generation: "generation-1",
    coordinator_nonce: "nonce-1",
    coordinator_session_id: "session-1",
    coordinator_timestamp: "2030-01-02T02:59:05Z",
    domain: "darkbloom.process_evidence",
    evidence_expires_at: "2030-01-02T04:04:05Z",
    metallib_hash: "22".repeat(32),
    process_public_key: fields.processKey,
    provider_backend: "mlx",
    provider_platform: "macos-arm64",
    provider_version: "2.0.0",
    runtime_hash: "33".repeat(32),
    se_public_key: fields.seKey,
    secure_boot_enabled: true,
    serial_number: fields.serial,
    sip_enabled: true,
    version: "process_evidence_v1",
  });
}

async function generatedProof(options: {
  badFreshness?: boolean;
  attestedSerial?: string;
} = {}): Promise<{
  certificate: ProcessCertificate;
  root: ArrayBuffer;
}> {
  const algorithm = { name: "ECDSA", namedCurve: "P-256" } as const;
  const signingAlgorithm = { name: "ECDSA", hash: "SHA-256" } as const;
  const rootKeys = await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"]);
  const leafKeys = await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"]);
  const seKeys = await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"]);
  const root = await X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Private V2 Test Root",
    notBefore: new Date("2029-01-01T00:00:00Z"),
    notAfter: new Date("2031-01-01T00:00:00Z"),
    signingAlgorithm,
    keys: rootKeys,
    extensions: [
      new BasicConstraintsExtension(true, 1, true),
      new KeyUsagesExtension(KeyUsageFlags.keyCertSign | KeyUsageFlags.cRLSign, true),
    ],
  });
  const seRaw = new Uint8Array(await crypto.subtle.exportKey("raw", seKeys.publicKey));
  const seKey = standardBase64(seRaw);
  const freshness = new Uint8Array(await crypto.subtle.digest(
    "SHA-256",
    arrayBuffer(new TextEncoder().encode(seKey)),
  ));
  const attestedFreshness = options.badFreshness ? new Uint8Array(32) : freshness;
  const serial = "SERIAL-TEST-1";
  const leaf = await X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Private V2 Test Leaf",
    issuer: root.subject,
    notBefore: new Date("2029-01-01T00:00:00Z"),
    notAfter: new Date("2031-01-01T00:00:00Z"),
    signingAlgorithm,
    publicKey: leafKeys.publicKey,
    signingKey: rootKeys.privateKey,
    extensions: [
      new BasicConstraintsExtension(false, undefined, true),
      new Extension(FRESHNESS_OID, false, arrayBuffer(derValue(0x04, attestedFreshness))),
      new Extension(SERIAL_OID, false, arrayBuffer(derValue(
        0x0c,
        new TextEncoder().encode(options.attestedSerial || serial),
      ))),
    ],
  });
  const processKey = standardBase64(Uint8Array.from({ length: 32 }, (_, index) => index + 1));
  const evidence = canonicalEvidence({ processKey, seKey, serial });
  const rawSignature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    seKeys.privateKey,
    arrayBuffer(new TextEncoder().encode(evidence)),
  ));
  return {
    root: root.rawData,
    certificate: {
      backend: "mlx",
      expires_at: "2030-01-02T04:04:05Z",
      mda_der_chain: [base64Url(new Uint8Array(leaf.rawData))],
      metallib_hash: "22".repeat(32),
      mlx_nax: false,
      platform: "macos-arm64",
      policy_generation: 7,
      process_evidence_signature: base64Url(derSignature(rawSignature)),
      process_evidence_transcript: base64Url(new TextEncoder().encode(evidence)),
      process_public_key: processKey,
      provider_version: "2.0.0",
      release_binary_hash: "11".repeat(32),
      runtime_hash: "33".repeat(32),
      se_public_key: seKey,
      verified_at: "2030-01-02T03:00:05Z",
      version: "process_certificate_v1",
    },
  };
}

describe("private-v2 independent process attestation", () => {
  it("validates chain constraints, freshness, serial, process fields, and SE signature", async () => {
    const proof = await generatedProof();
    await expect(verifyProcessCertificateAttestationAgainstRoot(
      proof.certificate,
      proof.root,
      NOW,
    )).resolves.toMatchObject({
      processPublicKey: proof.certificate.process_public_key,
      releaseBinaryHash: proof.certificate.release_binary_hash,
      sePublicKey: proof.certificate.se_public_key,
    });
  });

  it("rejects a synthetic coordinator certificate against the pinned Apple root", async () => {
    const proof = await generatedProof();
    await expect(verifyProcessCertificateAttestation(proof.certificate, NOW)).rejects.toThrow();
  });

  it("rejects tampered process evidence signatures", async () => {
    const proof = await generatedProof();
    const tampered = {
      ...proof.certificate,
      process_evidence_signature:
        (proof.certificate.process_evidence_signature[0] === "A" ? "B" : "A") +
        proof.certificate.process_evidence_signature.slice(1),
    };
    await expect(verifyProcessCertificateAttestationAgainstRoot(
      tampered,
      proof.root,
      NOW,
    )).rejects.toThrow("signature");
  });

  it("rejects MDA freshness and serial proofs that do not join to signed process evidence", async () => {
    const badFreshness = await generatedProof({ badFreshness: true });
    await expect(verifyProcessCertificateAttestationAgainstRoot(
      badFreshness.certificate,
      badFreshness.root,
      NOW,
    )).rejects.toThrow("freshness");

    const badSerial = await generatedProof({ attestedSerial: "SERIAL-OTHER" });
    await expect(verifyProcessCertificateAttestationAgainstRoot(
      badSerial.certificate,
      badSerial.root,
      NOW,
    )).rejects.toThrow("serial");
  });

  it("rejects coordinator substitutions of certified process and release fields", async () => {
    const proof = await generatedProof();
    await expect(verifyProcessCertificateAttestationAgainstRoot(
      { ...proof.certificate, process_public_key: standardBase64(new Uint8Array(32)) },
      proof.root,
      NOW,
    )).rejects.toThrow("certificate mismatch");
    await expect(verifyProcessCertificateAttestationAgainstRoot(
      { ...proof.certificate, release_binary_hash: "ff".repeat(32) },
      proof.root,
      NOW,
    )).rejects.toThrow("certificate mismatch");
  });
});
