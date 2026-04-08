"use client";

import { useState, useEffect } from "react";
import { ShieldCheck, Info } from "lucide-react";
import { TrustExplainerModal } from "./TrustExplainerModal";

const ATTESTATION_API = "https://inference-test.openinnovation.dev";

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
        const res = await fetch(`${ATTESTATION_API}/v1/providers/attestation`);
        if (!res.ok) return;
        const data = await res.json();
        if (cancelled) return;

        const providers = data.providers || [];
        const attested = providers.filter(
          (p: { trust_level: string }) => p.trust_level === "hardware"
        );
        const count = attested.length;

        // Find most recent challenge timestamp
        let lastTime = 0;
        for (const p of attested) {
          if (p.last_challenge_time) {
            const t = new Date(p.last_challenge_time).getTime();
            if (t > lastTime) lastTime = t;
          }
        }

        const ago = lastTime
          ? formatTimeAgo(Date.now() - lastTime)
          : "recently";

        setSummary({ count, lastVerified: ago });
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

function formatTimeAgo(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}
