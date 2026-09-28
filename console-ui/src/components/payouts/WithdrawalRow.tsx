import { Check, Clock, X } from "lucide-react";
import type { StripeWithdrawal } from "@/lib/api";
import { formatUsd, microToUsd } from "@/lib/format";
import { formatBankAmount } from "./bank-withdrawal-format";
import { withdrawalStatusPresentation } from "./payout-copy";

export function WithdrawalRow({ withdrawal: w }: { withdrawal: StripeWithdrawal }) {
  const presentation = withdrawalStatusPresentation(w.status, w.refunded, w.failure_reason);
  const Icon = w.status === "paid" ? Check : w.status === "failed" ? X : Clock;
  const color = w.status === "paid" ? "text-teal" : w.status === "failed" ? "text-coral" : "text-text-tertiary";
  const requested = new Date(w.created_at);
  const requestedISO = Number.isFinite(requested.getTime()) ? requested.toISOString() : null;

  return (
    <li className="text-sm">
      <div className="flex items-center justify-between gap-2 flex-wrap">
        <div className="flex items-center gap-2">
          <Icon size={12} className={color} aria-hidden="true" />
          <span className="font-mono text-text-secondary">
            {w.payout_rail === "global" && w.payout_currency && w.destination_amount
              ? formatBankAmount(w.destination_amount, w.payout_currency, w.currency_exponent ?? 2)
              : formatUsd(microToUsd(w.net_micro_usd))}
          </span>
          <span className="text-[10px] font-mono uppercase text-text-tertiary">{w.method}</span>
        </div>
        <span className={`text-xs font-mono ${color}`}>{presentation.label}</span>
      </div>
      <p className="text-xs text-text-secondary mt-1">{presentation.detail}</p>
      <details className="mt-1 text-xs text-text-tertiary">
        <summary className="cursor-pointer">Withdrawal details</summary>
        <dl className="mt-2 space-y-1">
          <div>
            <dt className="inline">Withdrawal ID: </dt>
            <dd className="inline font-mono break-all select-all">{w.id}</dd>
          </div>
          <div>
            <dt className="inline">Requested: </dt>
            <dd className="inline">
              {requestedISO ? (
                <time dateTime={requestedISO}>
                  {requestedISO.replace("T", " ").replace(/\.\d{3}Z$/, " UTC")}
                </time>
              ) : "Date unavailable"}
            </dd>
          </div>
        </dl>
        <p className="mt-2">Include this ID and date when contacting support.</p>
      </details>
    </li>
  );
}
