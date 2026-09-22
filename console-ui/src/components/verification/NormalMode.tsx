"use client";
import type { TrustMetadata } from "@/lib/api";
import { ProofDetails } from "./ProofDetails";

export function NormalMode({ trust, onOpenExplainer }: { trust: TrustMetadata; onOpenExplainer: () => void }) {
  return <div className="space-y-3">
    <ProofDetails verification={trust.verification} historical />
    <p className="text-xs text-text-secondary">{trust.encrypted
      ? "The coordinator encrypted this request to the provider. Request bodies are decrypted inside the coordinator’s confidential VM for routing and billing, then re-encrypted to the provider."
      : "Provider-hop encryption status is unavailable for this message."}</p>
    <button onClick={onOpenExplainer} className="text-xs font-semibold text-teal hover:underline">Learn how the trust chain works</button>
  </div>;
}
