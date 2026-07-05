"use client";

import { useState, useEffect } from "react";
import { ShieldCheck, Info } from "lucide-react";
import { formatRelative } from "@/lib/format";
import { TrustExplainerModal } from "./TrustExplainerModal";

interface ProviderSummary {
  count: number;
  lastVerified: string;
}

export function PreSendTrustBanner({ visible }: { visible: boolean }) {
  const [summary, setSummary] = useState<ProviderSummary | null>(null);
  const [showExplainer, setShowExplainer] = useState(false);

  useEffect(() => {
    if (!visible) return;

    let cancelled = false;

    async function fetchProviders() {
      try {
        // Slim same-origin summary instead of downloading the full attestation
        // blob (cert chains) just for a count + timestamp (perf F9b).
        const res = await fetch(`/api/attestation?summary=1`);
        if (!res.ok) return;
        const data = (await res.json()) as { count?: number; last_verified?: string | null };
        if (cancelled) return;

        setSummary({
          count: data.count ?? 0,
          lastVerified: data.last_verified ? formatRelative(data.last_verified) : "recently",
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
      <div className="max-w-4xl mx-auto px-3 sm:px-6 pb-2">
        <div className="flex items-center gap-2 px-4 py-2.5 rounded-xl bg-teal-light/40 border-2 border-teal/30">
          <ShieldCheck size={16} className="text-teal shrink-0" />
          <p className="text-xs text-text-secondary flex-1 leading-relaxed">
            <span className="font-semibold text-text-primary">
              End-to-end encrypted
            </span>{" "}
            &mdash; processed on Apple-verified hardware
            {summary && (
              <span className="text-text-tertiary">
                {" "}
                &middot; {summary.count} provider{summary.count !== 1 ? "s" : ""}{" "}
                online &middot; Last verified {summary.lastVerified}
              </span>
            )}
          </p>
          <button
            onClick={() => setShowExplainer(true)}
            className="shrink-0 flex items-center gap-1 px-2 py-1 rounded-lg text-xs font-semibold text-teal hover:bg-teal-light/60 transition-colors"
          >
            <Info size={12} />
            <span className="hidden sm:inline">How it works</span>
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
