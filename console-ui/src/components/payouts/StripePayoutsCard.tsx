"use client";

import { Building2, ArrowDownToLine, Loader2 } from "lucide-react";
import { type StripeStatus, type StripeWithdrawal } from "@/lib/api";
import { STRIPE_CONNECT_COUNTRIES } from "@/lib/stripe-countries";
import { microToUsd } from "@/lib/format";
import { CountryPicker } from "./CountryPicker";
import { PayoutDestinationRow } from "./PayoutDestinationRow";
import { WithdrawalsList } from "./WithdrawalsList";

// Shared "withdraw to bank" card (Stripe Connect Express). Renders the status
// badge, the onboarding / ready / action-needed bodies (with the shared
// CountryPicker), the withdraw CTA, and the recent-withdrawals list. Billing
// and earnings pass their own wrapper styling, title, and balance slot
// (proposal F3).
export function StripePayoutsCard({
  status,
  withdrawals,
  confirmationPending = false,
  balanceMicroUsd,
  onboardLoading,
  selectedCountry,
  onCountryChange,
  onOnboard,
  onOpenWithdraw,
  onOpenDashboard,
  dashboardLoading,
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
  confirmationPending?: boolean;
  balanceMicroUsd: number;
  onboardLoading: boolean;
  selectedCountry: string;
  onCountryChange: (country: string) => void;
  onOnboard: () => void;
  onOpenWithdraw: () => void;
  /** Open the Stripe Express Dashboard to change the payout destination. */
  onOpenDashboard?: () => void;
  dashboardLoading?: boolean;
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

  const ready = status?.status === "ready" || confirmationPending;
  const restricted = status?.status === "restricted";
  const rejected = status?.status === "rejected";
  const pending = status?.status === "pending";
  const balanceUsd = microToUsd(balanceMicroUsd);
  const minWithdrawUsd = microToUsd(status?.min_withdraw_micro_usd ?? 1_000_000);
  const canWithdraw = confirmationPending || (ready && status?.payouts_available !== false && balanceUsd >= minWithdrawUsd);

  return (
    <div className={className}>
      <div className="flex items-center gap-2 mb-4">
        {icon}
        <h3 className="text-sm font-semibold text-text-primary">{title}</h3>
        {ready && (
          <span className="ml-auto text-[10px] font-mono uppercase tracking-widest text-teal bg-teal/10 border border-teal/30 rounded px-2 py-0.5">
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
      {status?.payouts_available === false && <p role="status" className="text-sm text-coral mb-4">Bank withdrawals are temporarily unavailable. Your earnings remain in your account.</p>}

      {!status?.has_account ? (
        <>
          <p className="text-sm text-text-secondary mb-4 leading-relaxed">
            Set up a bank account to withdraw your {noun}.
            Stripe securely collects your bank details and any required identification.
          </p>
          <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
            Your country
          </label>
          <CountryPicker options={status?.countries} value={selectedCountry} onChange={onCountryChange} />
          <button
            onClick={onOnboard}
            disabled={onboardLoading || !selectedCountry || status?.payouts_available === false}
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all"
          >
            {onboardLoading ? <Loader2 size={14} className="animate-spin" /> : <Building2 size={14} />}
            {onboardLoading ? "Redirecting..." : "Link bank via Stripe"}
          </button>
          {!selectedCountry && (
            <p className="text-xs text-text-tertiary mt-2">
              Select your country to continue. Your bank account must be in your country of residence.
            </p>
          )}
        </>
      ) : ready ? (
        <>
          <PayoutDestinationRow
            status={status}
            onOpenDashboard={onOpenDashboard}
            dashboardLoading={dashboardLoading}
          />
          <button
            onClick={onOpenWithdraw}
            disabled={!canWithdraw}
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all"
          >
            <ArrowDownToLine size={14} />
            {confirmationPending ? "Check withdrawal" : "Withdraw"}
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
            Your payout details are set up for{" "}
            <span className="font-medium text-text-primary">
              {(status?.countries ?? STRIPE_CONNECT_COUNTRIES).find((c) => c.code === status?.stripe_account_country)?.name || status?.stripe_account_country || "your selected country"}
            </span>
            . Continue in Stripe to finish setup or update your details. If the country is incorrect, choose it below.
          </p>
          <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
            Country
          </label>
          <CountryPicker options={status?.countries} value={selectedCountry} onChange={onCountryChange} />
          <button
            onClick={onOnboard}
            disabled={onboardLoading || !selectedCountry || status?.payouts_available === false}
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 transition-all"
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
