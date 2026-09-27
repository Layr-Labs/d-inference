"use client";
import type { TrustMetadata } from "@/lib/api";
import { ProofDetails } from "./ProofDetails";

export function TechnicalMode({ trust }: { trust: TrustMetadata }) {
  return <div className="space-y-3">
    <ProofDetails verification={trust.verification} historical />
    <p className="text-xs text-text-secondary">Legacy trust field: {trust.trustLevel}. Legacy MDA proof: {trust.mdaVerified ? "reported verified" : "not reported verified"}. These fields do not establish App Attest authorization.</p>
    <p className="text-xs text-text-secondary">Per-response signature: {trust.seSignature ? "received; browser verification not performed" : "unavailable"}. This is separate from Apple’s App Attest receipt.</p>
    {trust.responseHash && <p className="break-all font-mono text-xs text-text-tertiary">Response hash: {trust.responseHash}</p>}
    <p className="text-xs text-text-secondary">SIP, Secure Boot, anti-debugging and memory-wiping evidence are not published in this response. No per-check guarantee is inferred from the legacy trust field.</p>
  </div>;
}
