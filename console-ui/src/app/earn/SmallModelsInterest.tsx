"use client";

import { ArrowRight, ClipboardList } from "lucide-react";
import Link from "next/link";
import { trackEvent } from "@/lib/google-analytics";
import type { EarningsCalculator } from "./useEarningsCalculator";

/**
 * Shown when the selected hardware can't run any current catalog model:
 * sends the visitor to the durable provider availability form with their
 * calculator selections prefilled.
 */
export function SmallModelsInterest({
  calc,
}: {
  calc: EarningsCalculator;
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
            source: "earn_page",
            chip: calc.selectedChip,
            memory_gb: calc.effectiveRAM,
          })
        }
        className="inline-flex items-center justify-center gap-2 px-5 py-2.5 rounded-lg
                   bg-accent-brand text-white font-medium text-sm
                   hover:bg-accent-brand-hover
                   transition-colors focus-ring"
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
