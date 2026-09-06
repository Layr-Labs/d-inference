"use client";

// Body of the payout-setup dialog opened from the hero CTA when Stripe is not
// linked-and-ready yet. Replaces the old standalone "Payout destination" card;
// reuses the shared payouts building blocks (CountryPicker, unlink) and the
// same onboard flow, so billing's StripePayoutsCard is untouched.

import { Building2, Loader2 } from "lucide-react";
import type { StripeStatus } from "@/lib/api";
import { STRIPE_CONNECT_COUNTRIES } from "@/lib/stripe-countries";
import { CountryPicker } from "@/components/payouts";

export function PayoutSetupModal({
  status,
  onboardLoading,
  selectedCountry,
  onCountryChange,
  onOnboard,
  onUnlink,
  unlinkLoading,
}: {
  status: StripeStatus | null;
  onboardLoading: boolean;
  selectedCountry: string;
  onCountryChange: (country: string) => void;
  onOnboard: () => void;
  onUnlink: () => void;
  unlinkLoading: boolean;
}) {
  const restricted = status?.status === "restricted";
  const hasAccount = Boolean(status?.has_account);
  const countryName =
    STRIPE_CONNECT_COUNTRIES.find((c) => c.code === status?.stripe_account_country)
      ?.name ||
    status?.stripe_account_country ||
    "your selected country";

  const buttonLabel = () => {
    if (onboardLoading) return "Redirecting...";
    if (!hasAccount) return "Link bank via Stripe";
    return restricted ? "Provide more info" : "Continue setup";
  };

  return (
    <div className="px-6 pb-6">
      <h3 className="text-2xl font-semibold text-ink mb-2">Set up payouts</h3>
      {hasAccount ? (
        <p className="text-sm text-text-secondary mb-4 leading-relaxed">
          Your Stripe account is locked to{" "}
          <span className="font-medium text-text-primary">{countryName}</span>.
          Finish Stripe&apos;s verification to unlock withdrawals. If the
          country is wrong, pick the right one below and we will create a new
          account.
        </p>
      ) : (
        <p className="text-sm text-text-secondary mb-4 leading-relaxed">
          Link a bank account or debit card via Stripe to withdraw your
          earnings. Stripe handles identity verification — onboarding takes
          about 2 minutes.
        </p>
      )}
      <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
        Your country
      </label>
      <CountryPicker value={selectedCountry} onChange={onCountryChange} />
      <button
        onClick={onOnboard}
        disabled={onboardLoading || !selectedCountry}
        className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all"
      >
        {onboardLoading ? (
          <Loader2 size={14} className="animate-spin" />
        ) : (
          <Building2 size={14} />
        )}
        {buttonLabel()}
      </button>
      {!selectedCountry && (
        <p className="text-xs text-text-tertiary mt-2">
          Select your country to continue. This determines your payout currency
          and KYC requirements.
        </p>
      )}
      {hasAccount && (
        <button
          onClick={onUnlink}
          disabled={unlinkLoading}
          className="mt-3 block text-xs text-text-tertiary underline underline-offset-2 hover:text-coral disabled:opacity-50 transition-colors"
        >
          {unlinkLoading ? "Unlinking..." : "Unlink Stripe account and start over"}
        </button>
      )}
    </div>
  );
}
