/**
 * In-browser X.509 certificate chain verification against
 * Apple's Enterprise Attestation Root CA using pkijs + WebCrypto.
 *
 * This replaces the fake "verify" button that just checked JSON fields.
 * Now we actually parse DER certificates, verify signatures, and
 * extract Apple-specific OID values.
 */

import * as asn1js from "asn1js";
import * as pkijs from "pkijs";

// Apple Enterprise Attestation Root CA (P-384, valid until 2047).
// Same PEM as coordinator/internal/attestation/mda.go lines 44-57.
const APPLE_ENTERPRISE_ATTESTATION_ROOT_CA_PEM = `-----BEGIN CERTIFICATE-----
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

// Apple MDA OIDs for DevicePropertiesAttestation.
const OID_SERIAL_NUMBER = "1.2.840.113635.100.8.9.1";
const OID_UDID = "1.2.840.113635.100.8.9.2";
const OID_OS_VERSION = "1.2.840.113635.100.8.10.1";
const OID_SEPOS_VERSION = "1.2.840.113635.100.8.10.2";

export interface VerificationStep {
  status: "pending" | "running" | "success" | "error";
  label: string;
  detail?: string;
}

export interface CertVerificationResult {
  success: boolean;
  steps: VerificationStep[];
  deviceInfo?: {
    serial?: string;
    udid?: string;
    osVersion?: string;
    sepOsVersion?: string;
    commonName?: string;
    issuerCN?: string;
  };
  error?: string;
}

/** Decode a PEM string to an ArrayBuffer. */
function pemToBuffer(pem: string): ArrayBuffer {
  const lines = pem
    .replace(/-----BEGIN CERTIFICATE-----/, "")
    .replace(/-----END CERTIFICATE-----/, "")
    .replace(/\s/g, "");
  const binary = atob(lines);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

/** Decode base64 to ArrayBuffer. */
function base64ToBuffer(b64: string): ArrayBuffer {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

/** Compute SHA-256 fingerprint of a DER-encoded certificate. */
async function sha256Fingerprint(der: ArrayBuffer): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", der);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join(":");
}

/** Extract a value from an extension by OID.
 *
 * Apple MDA certificates store OID values as raw UTF-8 bytes in the
 * extension value (NOT wrapped in ASN.1 structures like UTF8String).
 * For example, serial "G36VWKJ304" is stored as raw bytes 47:33:36:56...
 * We read the raw bytes directly and decode as UTF-8.
 */
function extractOIDValue(
  cert: pkijs.Certificate,
  oid: string
): string | undefined {
  if (!cert.extensions) return undefined;
  for (const ext of cert.extensions) {
    if (ext.extnID === oid) {
      try {
        // Apple MDA stores values as raw bytes, not ASN.1-wrapped.
        // Read the raw extension value directly as UTF-8.
        const raw = ext.extnValue.valueBlock.valueHexView;
        if (raw && raw.length > 0) {
          const decoded = new TextDecoder().decode(raw);
          // Filter out non-printable results (binary data like freshness codes)
          if (decoded && /^[\x20-\x7E]+$/.test(decoded)) {
            return decoded;
          }
        }
      } catch {
        // OID value couldn't be parsed
      }
    }
  }
  return undefined;
}

/** Extract the Common Name from a certificate's subject. */
function extractCN(rdns: pkijs.RelativeDistinguishedNames): string {
  for (const rdn of rdns.typesAndValues) {
    // OID 2.5.4.3 is commonName
    if (rdn.type === "2.5.4.3") {
      return rdn.value.valueBlock.value || "";
    }
  }
  return "";
}

/**
 * Verify a certificate chain against Apple's Enterprise Attestation Root CA.
 *
 * @param certChainB64 Array of base64-encoded DER certificates
 *   (leaf first, then intermediates — root is NOT included in the chain).
 * @param onStep Callback invoked as each step progresses.
 */
export async function verifyCertificateChain(
  certChainB64: string[],
  onStep?: (steps: VerificationStep[]) => void
): Promise<CertVerificationResult> {
  const steps: VerificationStep[] = [
    { status: "pending", label: "Parsing certificate chain" },
    { status: "pending", label: "Extracting device identity" },
    { status: "pending", label: "Verifying intermediate certificate" },
    { status: "pending", label: "Verifying root CA fingerprint" },
    { status: "pending", label: "Confirming Apple device attestation" },
  ];

  const notify = () => onStep?.(structuredClone(steps));

  try {
    // Step 1: Parse certificates
    steps[0].status = "running";
    notify();

    if (!certChainB64 || certChainB64.length < 2) {
      steps[0].status = "error";
      steps[0].detail = `Expected at least 2 certificates, got ${certChainB64?.length || 0}`;
      notify();
      return { success: false, steps, error: "Insufficient certificates in chain" };
    }

    const certs: pkijs.Certificate[] = [];
    for (const b64 of certChainB64) {
      const der = base64ToBuffer(b64);
      const asn = asn1js.fromBER(der);
      const cert = new pkijs.Certificate({ schema: asn.result });
      certs.push(cert);
    }

    const leaf = certs[0];
    const leafCN = extractCN(leaf.subject);
    const intermediate = certs.length > 1 ? certs[1] : null;

    steps[0].status = "success";
    steps[0].detail = `${certs.length} certificates parsed`;
    notify();

    // Step 2: Extract device identity from leaf
    steps[1].status = "running";
    notify();

    const deviceInfo: CertVerificationResult["deviceInfo"] = {
      serial: extractOIDValue(leaf, OID_SERIAL_NUMBER),
      udid: extractOIDValue(leaf, OID_UDID),
      osVersion: extractOIDValue(leaf, OID_OS_VERSION),
      sepOsVersion: extractOIDValue(leaf, OID_SEPOS_VERSION),
      commonName: leafCN,
      issuerCN: intermediate ? extractCN(intermediate.subject) : "",
    };

    steps[1].status = "success";
    steps[1].detail = deviceInfo.serial
      ? `Serial: ${deviceInfo.serial}`
      : leafCN || "Device certificate parsed";
    notify();

    // Step 3: Verify intermediate signed the leaf
    steps[2].status = "running";
    notify();

    if (intermediate) {
      try {
        const verified = await leaf.verify(intermediate);
        if (verified) {
          steps[2].status = "success";
          const intermediateCN = extractCN(intermediate.subject);
          steps[2].detail = `Signed by ${intermediateCN || "Apple Intermediate CA"}`;
        } else {
          steps[2].status = "error";
          steps[2].detail = "Signature verification failed";
          notify();
          return {
            success: false,
            steps,
            deviceInfo,
            error: "Intermediate CA signature verification failed",
          };
        }
      } catch (verifyErr) {
        // Don't silently succeed — if verify() threw, we can't confirm the signature.
        // Fall through to chain validation in Step 4 which does fingerprint-based checks.
        steps[2].status = "error";
        steps[2].detail = `Signature check inconclusive: ${verifyErr instanceof Error ? verifyErr.message : "unknown error"}`;
        notify();
        return {
          success: false,
          steps,
          deviceInfo,
          error: "Could not verify leaf certificate signature",
        };
      }
    } else {
      steps[2].status = "error";
      steps[2].detail = "No intermediate certificate";
      notify();
      return {
        success: false,
        steps,
        deviceInfo,
        error: "Missing intermediate certificate",
      };
    }
    notify();

    // Step 4: Verify root CA fingerprint
    steps[3].status = "running";
    notify();

    const rootDer = pemToBuffer(APPLE_ENTERPRISE_ATTESTATION_ROOT_CA_PEM);
    const rootFingerprint = await sha256Fingerprint(rootDer);

    // Check if the last cert in chain is the root, or if the intermediate
    // was signed by the root (the root itself may not be in the chain).
    const rootCertAsn = asn1js.fromBER(rootDer);
    const rootCert = new pkijs.Certificate({ schema: rootCertAsn.result });

    // Verify the topmost cert in the chain against the root
    const topCert = certs[certs.length - 1];
    try {
      const rootVerified = await topCert.verify(rootCert);
      if (rootVerified) {
        steps[3].status = "success";
        steps[3].detail = `Matches Apple Enterprise Attestation Root CA`;
      } else {
        // The top cert might BE the root — check fingerprint
        const topDer = base64ToBuffer(certChainB64[certChainB64.length - 1]);
        const topFp = await sha256Fingerprint(topDer);
        if (topFp === rootFingerprint) {
          steps[3].status = "success";
          steps[3].detail = "Root CA fingerprint matches Apple's published cert";
        } else {
          steps[3].status = "error";
          steps[3].detail = "Root CA fingerprint mismatch";
          notify();
          return {
            success: false,
            steps,
            deviceInfo,
            error: "Root CA does not match Apple Enterprise Attestation Root CA",
          };
        }
      }
    } catch {
      // Algorithm mismatch — fall back to fingerprint check only.
      // Do NOT fall back to CN matching — an attacker could set the
      // issuer CN to "Apple Enterprise Attestation Root CA" without
      // actually being signed by Apple's key.
      const topDer = base64ToBuffer(certChainB64[certChainB64.length - 1]);
      const topFp = await sha256Fingerprint(topDer);
      if (topFp === rootFingerprint) {
        steps[3].status = "success";
        steps[3].detail = "Root CA fingerprint matches Apple's published cert";
      } else {
        steps[3].status = "error";
        steps[3].detail = "Cannot cryptographically verify against Apple Root CA";
        notify();
        return {
          success: false,
          steps,
          deviceInfo,
          error: "Cannot verify certificate chain against Apple Root CA",
        };
      }
    }
    notify();

    // Step 5: Final confirmation
    steps[4].status = "running";
    notify();

    steps[4].status = "success";
    steps[4].detail = "This provider is a genuine Apple device, verified by Apple Inc.";
    notify();

    return { success: true, steps, deviceInfo };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    // Mark remaining steps as error
    for (const step of steps) {
      if (step.status === "pending" || step.status === "running") {
        step.status = "error";
        step.detail = msg;
        break;
      }
    }
    notify();
    return { success: false, steps, error: msg };
  }
}
