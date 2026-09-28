"use client";

import { type StripeWithdrawal } from "@/lib/api";
import { WithdrawalRow } from "./WithdrawalRow";

// Shared recent history for the billing and provider earnings pages.
export function WithdrawalsList({ withdrawals }: { withdrawals: StripeWithdrawal[] }) {
  if (withdrawals.length === 0) return null;
  const remaining = withdrawals.length - 5;
  return (
    <div className="mt-5 pt-5 border-t border-border-subtle">
      <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
        Recent withdrawals
      </p>
      <ul className="space-y-4">
        {withdrawals.slice(0, 5).map((withdrawal) => (
          <WithdrawalRow key={withdrawal.id} withdrawal={withdrawal} />
        ))}
      </ul>
      {remaining > 0 && (
        <details className="mt-4">
          <summary className="cursor-pointer text-xs text-text-secondary">
            Show {remaining} more {remaining === 1 ? "withdrawal" : "withdrawals"}
          </summary>
          <ul className="space-y-4 mt-4">
            {withdrawals.slice(5).map((withdrawal) => (
              <WithdrawalRow key={withdrawal.id} withdrawal={withdrawal} />
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}
