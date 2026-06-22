"use client";

import { useCallback, useState } from "react";
import type { TrustMetadata } from "@/lib/api";
// Type-only import: erased at compile time, so it does NOT pull pkijs/asn1js
// into the bundle. The implementation is loaded lazily inside verify() below.
import type { VerificationStep, CertVerificationResult } from "@/lib/cert-verify";
import type { ProviderDetail } from "./types";

/**
 * Device attestation verification state + action. The heavy X.509 verifier
 * (pkijs + asn1js, ~76 KB gz) is dynamically imported only when the user clicks
 * "Verify", keeping it off the First Load of the chat/stats/providers routes
 * (perf F4).
 */
export function useDeviceVerification(trust: TrustMetadata) {
  const [verifying, setVerifying] = useState(false);
  const [verifySteps, setVerifySteps] = useState<VerificationStep[]>([]);
  const [verifyResult, setVerifyResult] = useState<CertVerificationResult | null>(null);
  const [providerDetail, setProviderDetail] = useState<ProviderDetail | null>(null);

  const verify = useCallback(async () => {
    setVerifying(true);
    setVerifyResult(null);
    setVerifySteps([]);

    try {
      // Same-origin proxy (perf F9).
      const res = await fetch(`/api/attestation`);
      const data = await res.json();

      const provider =
        data.providers?.find(
          (p: { serial_number: string }) => p.serial_number === trust.providerSerial,
        ) || data.providers?.[0];

      if (!provider) {
        setVerifyResult({ success: false, steps: [], error: "Provider not found in attestation API" });
        return;
      }

      setProviderDetail({
        systemVolumeHash: provider.system_volume_hash,
        sePublicKey: provider.se_public_key,
        mdaSerial: provider.mda_serial,
        mdaOsVersion: provider.mda_os_version,
        mdaSepVersion: provider.mda_sepos_version,
        mdaCertCount: provider.mda_cert_chain_b64?.length || 0,
      });

      const certs: string[] = provider.mda_cert_chain_b64 || [];
      if (certs.length < 2) {
        setVerifyResult({
          success: false,
          steps: [{ status: "error", label: "Insufficient certificates", detail: `Got ${certs.length}, need at least 2` }],
          error: "Certificate chain too short for verification",
        });
        return;
      }

      // Lazy-load the heavy verifier only now (perf F4).
      const { verifyCertificateChain } = await import("@/lib/cert-verify");
      const result = await verifyCertificateChain(certs, (steps) => setVerifySteps(steps));
      setVerifyResult(result);
    } catch (e) {
      setVerifyResult({
        success: false,
        steps: [],
        error: `Error: ${e instanceof Error ? e.message : String(e)}`,
      });
    } finally {
      setVerifying(false);
    }
  }, [trust.providerSerial]);

  return { verifying, verifySteps, verifyResult, providerDetail, verify };
}
