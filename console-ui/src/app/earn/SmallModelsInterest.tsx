"use client";

import Link from "next/link";
import { ArrowRight, ClipboardList } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";
import type { EarningsCalculator } from "./useEarningsCalculator";

type InterestVariant = "smaller-models" | "production-readiness";

export function SmallModelsInterest({
  calc,
  variant = "smaller-models",
}: {
  calc: EarningsCalculator;
  authenticated?: boolean;
  ready?: boolean;
  login?: () => void;
  variant?: InterestVariant;
}) {
  const params = new URLSearchParams({
    chip: calc.selectedChip,
    memory_gb: String(calc.effectiveRAM),
  });

  return (
    <div className="mt-4">
      <Link
        href={`/provider-waitlist?${params.toString()}`}
        onClick={() =>
          trackEvent("provider_waitlist_opened", {
            source:
              variant === "production-readiness"
                ? "earn_page_production_readiness"
                : "earn_page_smaller_models",
            chip: calc.selectedChip,
            memory_gb: calc.effectiveRAM,
          })
        }
        className="inline-flex items-center justify-center gap-2 rounded-lg bg-accent-brand px-5 py-2.5 text-sm font-medium text-white transition-colors hover:bg-accent-brand-hover focus-ring"
      >
        <ClipboardList size={14} />
        Register this Mac&apos;s hardware interest
        <ArrowRight size={14} />
      </Link>
      <p className="mt-2 text-xs text-text-secondary">
        Share your email and hardware details for provider capacity planning.
      </p>
    </div>
  );
}
