import { Globe } from "lucide-react";

// Payout-coverage caveat shown above the Withdraw Earnings card — running
// a provider does not by itself guarantee a payout path in every region
// (Stripe Connect coverage varies by country).
export function PayoutCoverageNotice() {
  return (
    <div className="flex items-center gap-3.5 rounded-xl bg-accent-amber-dim/50 border border-accent-amber/10 shadow-sm px-5 py-4">
      <div
        className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-accent-amber/20 text-accent-amber"
        aria-hidden
      >
        <Globe size={16} />
      </div>
      <p className="text-sm leading-relaxed text-text-secondary">
        <span className="font-semibold text-text-primary">Heads up:</span>{" "}
        payouts aren&apos;t available in every country yet. Before you start
        serving requests, please check whether your country&apos;s withdrawal
        path is supported via Stripe. We&apos;re actively working on covering
        more regions.
      </p>
    </div>
  );
}
