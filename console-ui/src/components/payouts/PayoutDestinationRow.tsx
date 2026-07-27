"use client";

import { Building2, CreditCard, ExternalLink, Loader2 } from "lucide-react";
import { type StripeStatus } from "@/lib/api";

// Where a ready account's payouts land ("Bank ••6789"), plus the escape hatch
// to change it. Changing the destination is Stripe's job, not ours: the
// Express Dashboard owns bank/debit-card details and we only ever hold the
// last four digits, so the action opens a login link rather than a form.
export function PayoutDestinationRow({
  status,
  onOpenDashboard,
  dashboardLoading,
}: {
  status: StripeStatus;
  onOpenDashboard?: () => void;
  dashboardLoading?: boolean;
}) {
  const isCard = status.destination_type === "card";

  return (
    <div className="rounded-lg bg-bg-primary border border-border-dim p-3 mb-4 flex items-center justify-between gap-3">
      <div className="flex items-center gap-2 text-sm text-text-secondary">
        {isCard ? (
          <CreditCard size={14} className="text-teal" />
        ) : (
          <Building2 size={14} className="text-teal" />
        )}
        <span className="font-mono">
          {isCard ? "Debit card" : "Bank"} ••{status.destination_last4}
        </span>
        {status.instant_eligible && (
          <span className="text-[10px] font-mono uppercase text-gold bg-gold/10 border border-gold/30 rounded px-1.5 py-0.5">
            Instant
          </span>
        )}
      </div>
      {onOpenDashboard && (
        <button
          onClick={onOpenDashboard}
          disabled={dashboardLoading}
          title={`Opens your Stripe Express Dashboard, where you can change the ${isCard ? "debit card" : "bank account"} your payouts land in.`}
          className="flex items-center gap-1.5 shrink-0 text-xs text-text-tertiary underline underline-offset-2 hover:text-teal disabled:opacity-50 transition-colors"
        >
          {dashboardLoading ? (
            <Loader2 size={12} className="animate-spin" />
          ) : (
            <ExternalLink size={12} />
          )}
          {dashboardLoading ? "Opening..." : "Change in Stripe"}
        </button>
      )}
    </div>
  );
}
