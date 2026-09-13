"use client";

import { Sparkles } from "lucide-react";
import { MIN_PROVIDER_MEMORY_GB } from "./providerReadiness";
import { SmallModelsInterest } from "./SmallModelsInterest";
import type { EarningsCalculator } from "./useEarningsCalculator";

export function ProductionReadinessNotice({
  calc,
  authenticated,
  ready,
  login,
}: {
  calc: EarningsCalculator;
  authenticated: boolean;
  ready: boolean;
  login: () => void;
}) {
  return (
    <div className="mb-6 rounded-xl border border-accent-brand/20 bg-accent-brand-dim p-6 sm:p-8">
      <div className="flex items-start gap-3">
        <Sparkles
          size={20}
          className="mt-0.5 shrink-0 text-accent-brand"
          aria-hidden
        />
        <div>
          <p className="text-[10px] font-mono uppercase tracking-wider text-accent-brand">
            More Macs Support Coming Soon
          </p>
          <h2 className="mt-1 text-lg font-semibold text-text-primary">
            We&apos;re starting with Macs that have {MIN_PROVIDER_MEMORY_GB} GB or more
          </h2>
          <p className="mt-2 text-sm leading-relaxed text-text-secondary">
            Have a smaller Mac? We&apos;d still love to hear from you. Register your interest to
            help us plan support as we quickly expand Darkbloom to more machines.
          </p>
          <SmallModelsInterest
            calc={calc}
            authenticated={authenticated}
            ready={ready}
            login={login}
            variant="production-readiness"
          />
        </div>
      </div>
    </div>
  );
}
