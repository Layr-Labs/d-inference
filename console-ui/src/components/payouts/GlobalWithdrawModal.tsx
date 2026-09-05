"use client";

import { useEffect, useState } from "react";
import { ArrowRight, Building2, Loader2 } from "lucide-react";
import { formatBankAmount, validBankAmount, bankConfirmationLabel } from "./bank-withdrawal-format";
import type { BankWithdrawalQuote, StripeStatus } from "@/lib/api";

// Providers review the bank deposit and exchange estimate without choosing
// between Stripe products. The quote ID also identifies retries of a withdrawal.
export function GlobalWithdrawModal({ status, balanceMicroUsd, amount, loading, quote, confirmationPending = false, onAmountChange, onConfirm, onCancel }: {
  status: StripeStatus;
  balanceMicroUsd: number;
  amount: string;
  loading: boolean;
  quote?: BankWithdrawalQuote | null;
  confirmationPending?: boolean;
  onAmountChange: (value: string) => void;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, []);
  const balance = balanceMicroUsd / 1_000_000;
  const minimum = (status.min_withdraw_micro_usd ?? 1_000_000) / 1_000_000;
  const value = Number(amount);
  const valid = validBankAmount(amount) && value >= minimum && value <= balance;
  const matches = quote && Number(quote.amount_usd) === value;
  const expired = matches && Date.parse(quote.expires_at) <= now;
  const reviewing = Boolean(matches && (!expired || confirmationPending));
  const destinationLast4 = reviewing && quote ? quote.destination_last4 : status.destination_last4;
  const buttonLabel = bankConfirmationLabel(loading, confirmationPending, reviewing, Boolean(expired));

  return (
    <div className="px-6 pb-6">
      <h3 className="text-2xl font-semibold text-ink mb-2">Withdraw to your bank</h3>
      <p className="text-sm text-text-secondary mb-5 flex items-center gap-2">
        <Building2 size={15} />
        {destinationLast4 ? `Bank account ending in ${destinationLast4}` : "Your verified bank account"}
      </p>
      <label htmlFor="bank-withdrawal-amount" className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">Amount (USD)</label>
      <input id="bank-withdrawal-amount" type="number" inputMode="decimal" value={amount} min={minimum} max={balance} step="0.01" disabled={loading || confirmationPending}
        onChange={e => onAmountChange(e.target.value)}
        className="w-full bg-bg-primary border border-border-dim rounded-lg px-4 py-3 font-mono outline-none focus:border-teal disabled:opacity-60" />
      <p className="text-xs text-text-tertiary mt-2 mb-5">Available: ${balance.toFixed(2)} · Minimum: ${minimum.toFixed(2)}</p>
      {!confirmationPending && value > balance && <p role="alert" className="text-sm text-coral mb-4">This amount exceeds your available earnings.</p>}

      {reviewing && quote ? (
        <div className="bg-bg-primary rounded-lg border border-border-dim p-4 mb-5" aria-live="polite">
          <p className="text-xs text-text-tertiary mb-2">Estimated bank deposit</p>
          <p className="text-2xl font-semibold text-teal mb-3">{formatBankAmount(quote.destination_amount, quote.currency, quote.currency_exponent)}</p>
          <div className="flex justify-between text-sm text-text-secondary"><span>From your earnings</span><span>${Number(quote.amount_usd).toFixed(2)} USD</span></div>
          <div className="flex justify-between text-sm text-text-secondary mt-1"><span>Withdrawal fee</span><span>${Number(quote.fee_usd).toFixed(2)}</span></div>
          <p className="text-xs text-text-tertiary mt-3">{quote.eta}. The estimate includes Stripe&apos;s exchange rate. Your bank may apply its own charges.</p>
        </div>
      ) : (
        <p className="text-sm text-text-secondary mb-5" aria-live="polite">
          {expired ? "Your exchange estimate expired. Refresh it before confirming." : `Review the estimated ${status.payout_currency?.toUpperCase() ?? "local currency"} deposit before confirming. Your earnings are deducted only when you confirm.`}
        </p>
      )}
      {confirmationPending && <p role="status" className="text-sm text-text-secondary mb-4">We are confirming your existing withdrawal. Check its status before starting another.</p>}
      <div className="flex gap-3">
        <button onClick={onCancel} disabled={loading} className="flex-1 py-3 rounded-lg border border-border-dim text-sm font-bold disabled:opacity-50">{confirmationPending ? "Close" : "Cancel"}</button>
        <button onClick={onConfirm} disabled={loading || (!confirmationPending && !valid)} className="flex-1 py-3 rounded-lg bg-teal text-white text-sm font-bold flex items-center justify-center gap-2 disabled:opacity-50">
          {loading ? <Loader2 size={14} className="animate-spin" /> : <ArrowRight size={14} />}
          {buttonLabel}
        </button>
      </div>
    </div>
  );
}
