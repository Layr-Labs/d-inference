"use client";

import { Building2, CreditCard, ArrowDownToLine, Loader2 } from "lucide-react";
import { type StripeStatus, type StripeWithdrawal } from "@/lib/api";
import { STRIPE_CONNECT_COUNTRIES } from "@/lib/stripe-countries";
import { microToUsd } from "@/lib/format";
import { CountryPicker } from "./CountryPicker";
import { WithdrawalsList } from "./WithdrawalsList";

// Shared "withdraw to bank" card (Stripe Connect Express). Renders the status
// badge, the onboarding / ready / action-needed bodies (with the shared
// CountryPicker), the withdraw CTA, and the recent-withdrawals list. Billing
// and earnings pass their own wrapper styling, title, and balance slot
// (proposal F3).
export function StripePayoutsCard({
  status,
  withdrawals,
  balanceMicroUsd,
  onboardLoading,
  selectedCountry,
  onCountryChange,
  onOnboard,
  onOpenWithdraw,
  onUnlink,
  unlinkLoading,
  title,
  icon,
  noun,
  className,
  children,
}: {
  status: StripeStatus | null;
  withdrawals: StripeWithdrawal[];
  balanceMicroUsd: number;
  onboardLoading: boolean;
  selectedCountry: string;
  onCountryChange: (country: string) => void;
  onOnboard: () => void;
  onOpenWithdraw: () => void;
  /** Detach the linked Stripe account (escape hatch for wedged accounts). */
  onUnlink?: () => void;
  unlinkLoading?: boolean;
  title: string;
  icon: React.ReactNode;
  noun: string;
  className: string;
  children?: React.ReactNode;
}) {
  // Stripe payouts not configured on this coordinator — hide the card entirely.
  if (status && !status.configured) return null;

  const ready = status?.status === "ready";
  const restricted = status?.status === "restricted";
  const rejected = status?.status === "rejected";
  const pending = status?.status === "pending";
  const balanceUsd = microToUsd(balanceMicroUsd);
  const minWithdrawUsd = microToUsd(status?.min_withdraw_micro_usd ?? 1_000_000);
  const canWithdraw = ready && balanceUsd >= minWithdrawUsd;

  return (
    <div className={className}>
      <div className="flex items-center gap-2 mb-4">
        {icon}
        <h3 className="text-sm font-semibold text-text-primary">{title}</h3>
        {ready && (
          <span className="ml-auto text-[10px] font-mono uppercase tracking-widest text-blue bg-blue/10 border border-blue/30 rounded px-2 py-0.5">
            Ready
          </span>
        )}
        {pending && (
          <span className="ml-auto text-[10px] font-mono uppercase tracking-widest text-gold bg-gold/10 border border-gold/30 rounded px-2 py-0.5">
            Pending
          </span>
        )}
        {(restricted || rejected) && (
          <span className="ml-auto text-[10px] font-mono uppercase tracking-widest text-coral bg-coral/10 border border-coral/30 rounded px-2 py-0.5">
            Action needed
          </span>
        )}
      </div>

      {children}

      {!status?.has_account ? (
        <>
          <p className="text-sm text-text-secondary mb-4 leading-relaxed">
            Link a bank account or debit card via Stripe to withdraw your {noun}.
            Stripe handles identity verification — onboarding takes about 2 minutes.
          </p>
          <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
            Your country
          </label>
          <CountryPicker value={selectedCountry} onChange={onCountryChange} />
          <button
            onClick={onOnboard}
            disabled={onboardLoading || !selectedCountry}
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-blue border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all"
          >
            {onboardLoading ? <Loader2 size={14} className="animate-spin" /> : <Building2 size={14} />}
            {onboardLoading ? "Redirecting..." : "Link bank via Stripe"}
          </button>
          {!selectedCountry && (
            <p className="text-xs text-text-tertiary mt-2">
              Select your country to continue. This determines your payout currency and KYC requirements.
            </p>
          )}
        </>
      ) : ready ? (
        <>
          <div className="rounded-lg bg-bg-primary border border-border-dim p-3 mb-4 flex items-center justify-between">
            <div className="flex items-center gap-2 text-sm text-text-secondary">
              {status.destination_type === "card" ? (
                <CreditCard size={14} className="text-blue" />
              ) : (
                <Building2 size={14} className="text-blue" />
              )}
              <span className="font-mono">
                {status.destination_type === "card" ? "Debit card" : "Bank"} ••{status.destination_last4}
              </span>
              {status.instant_eligible && (
                <span className="text-[10px] font-mono uppercase text-gold bg-gold/10 border border-gold/30 rounded px-1.5 py-0.5">
                  Instant
                </span>
              )}
            </div>
          </div>
          <button
            onClick={onOpenWithdraw}
            disabled={!canWithdraw}
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-blue border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all"
          >
            <ArrowDownToLine size={14} />
            Withdraw
          </button>
          {!canWithdraw && balanceUsd < minWithdrawUsd && (
            <p className="text-xs text-text-tertiary mt-2">
              Minimum withdrawal is ${minWithdrawUsd.toFixed(2)} — your balance is ${balanceUsd.toFixed(2)}.
            </p>
          )}
        </>
      ) : (
        <>
          <p className="text-sm text-text-secondary mb-4 leading-relaxed">
            Your Stripe account is locked to{" "}
            <span className="font-medium text-text-primary">
              {STRIPE_CONNECT_COUNTRIES.find((c) => c.code === status?.stripe_account_country)?.name || status?.stripe_account_country || "your selected country"}
            </span>
            . If that is not correct, select your country below and we will create a new account.
          </p>
          <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
            Country
          </label>
          <CountryPicker value={selectedCountry} onChange={onCountryChange} />
          <button
            onClick={onOnboard}
            disabled={onboardLoading || !selectedCountry}
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-blue border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 transition-all"
          >
            {onboardLoading ? <Loader2 size={14} className="animate-spin" /> : <Building2 size={14} />}
            {onboardLoading ? "Redirecting..." : restricted ? "Provide more info" : "Continue setup"}
          </button>
          {onUnlink && (
            <button
              onClick={onUnlink}
              disabled={unlinkLoading}
              className="mt-3 block text-xs text-text-tertiary underline underline-offset-2 hover:text-coral disabled:opacity-50 transition-colors"
            >
              {unlinkLoading ? "Unlinking..." : "Unlink Stripe account and start over"}
            </button>
          )}
        </>
      )}

      <WithdrawalsList withdrawals={withdrawals} />
    </div>
  );
}
