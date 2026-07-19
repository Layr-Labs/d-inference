"use client";

import { Check, Clock, X } from "lucide-react";
import { type StripeWithdrawal } from "@/lib/api";
import { formatUsd, microToUsd } from "@/lib/format";
import { withdrawalStatusPresentation } from "./payout-copy";

// Recent-withdrawals list shown at the bottom of the payouts card. Identical in
// billing + earnings before this extraction (proposal F3).
export function WithdrawalsList({ withdrawals }: { withdrawals: StripeWithdrawal[] }) {
  if (withdrawals.length === 0) return null;
  return (
    <div className="mt-5 pt-5 border-t border-border-subtle">
      <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
        Recent withdrawals
      </p>
      <div className="space-y-2">
        {withdrawals.slice(0, 5).map((w) => {
          const presentation = withdrawalStatusPresentation(w.status, w.refunded);
          return (
            <div key={w.id} className="flex items-center justify-between text-sm">
              <div className="flex items-center gap-2">
                {w.status === "paid" ? (
                  <Check size={12} className="text-teal" />
                ) : w.status === "failed" ? (
                  <X size={12} className="text-coral" />
                ) : (
                  <Clock size={12} className="text-gold" />
                )}
                <span className="font-mono text-text-secondary">
                  {formatUsd(microToUsd(w.net_micro_usd))}
                </span>
                <span className="text-[10px] font-mono uppercase text-text-tertiary">
                  {w.source === "automatic" ? "weekly auto" : w.method}
                </span>
              </div>
              <span
                title={presentation.detail}
                className={`text-xs font-mono ${
                  w.status === "paid"
                    ? "text-teal"
                    : w.status === "failed"
                    ? "text-coral"
                    : "text-text-tertiary"
                }`}
              >
                {presentation.label}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
