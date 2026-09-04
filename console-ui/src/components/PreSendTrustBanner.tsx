"use client";

import { useState, useEffect } from "react";
import { ShieldCheck, Info } from "lucide-react";
import { formatRelative } from "@/lib/format";
import { TrustExplainerModal } from "./TrustExplainerModal";

interface ProviderSummary {
  count: number;
  lastVerified: string | null;
}

export function PreSendTrustBanner({ visible }: { visible: boolean }) {
  const [summary, setSummary] = useState<ProviderSummary | null>(null);
  const [showExplainer, setShowExplainer] = useState(false);

  useEffect(() => {
    if (!visible) return;

    let cancelled = false;

    async function fetchProviders() {
      try {
        // Slim same-origin summary for the count + timestamp banner.
        const res = await fetch(`/api/attestation?summary=1`);
        if (!res.ok) return;
        const data = (await res.json()) as { count?: number; last_verified?: string | null };
        if (cancelled) return;

        setSummary({
          count: data.count ?? 0,
          lastVerified: data.last_verified ? formatRelative(data.last_verified) : null,
        });
      } catch {
        // Silently fail — banner will just not show details
      }
    }

    fetchProviders();
    return () => {
      cancelled = true;
    };
  }, [visible]);

  if (!visible) return null;

  return (
    <>
      <div className="mx-auto mt-7 max-w-3xl">
        <div className="flex items-start justify-center gap-2 text-text-tertiary">
          <ShieldCheck size={14} className="mt-0.5 shrink-0" />
          <p className="text-xs leading-relaxed">
            End-to-end encrypted on verified hardware
            {summary && <span className="mt-1 block text-[11px]">{summary.count} provider{summary.count !== 1 ? "s" : ""} online.{summary.lastVerified ? ` Last verified ${summary.lastVerified}.` : ""}</span>}
          </p>
          <button
            onClick={() => setShowExplainer(true)}
            aria-label="How encryption and hardware verification work"
            className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-text-tertiary transition-colors hover:text-accent-brand"
          >
            <Info size={12} />
          </button>
        </div>
      </div>

      <TrustExplainerModal
        open={showExplainer}
        onClose={() => setShowExplainer(false)}
      />
    </>
  );
}
