"use client";

// The big "current balance" hero card. Owns the balance / withdrawable /
// credits split, and a payout-aware CTA: until Stripe is linked and ready the
// button walks the user toward setup instead of sitting disabled.

import { ArrowRight, Building2, CreditCard, ExternalLink, Loader2 } from "lucide-react";
import type { StripeStatus } from "@/lib/api";
import { formatMicroDollars } from "./format";

export interface HeroCta {
  label: string;
  /** "withdraw" opens the modal; "setup" jumps to the payout card. */
  action: "withdraw" | "setup";
  disabled: boolean;
  hint: string | null;
}

/** Pure mapping from payout state to the hero button's behavior. */
export function heroCta(
  status: StripeStatus | null,
  availableUsd: number,
  minWithdrawUsd: number,
): HeroCta {
  const withdraw = "Withdraw earnings";
  if (!status || !status.configured) {
    // Still loading, or payouts disabled on this coordinator.
    return { label: withdraw, action: "withdraw", disabled: true, hint: null };
  }
  if (!status.has_account) {
    return {
      label: "Link bank to withdraw",
      action: "setup",
      disabled: false,
      hint: "No payout method linked yet — takes about 2 minutes.",
    };
  }
  if (status.status === "pending") {
    return {
      label: "Finish payout setup",
      action: "setup",
      disabled: false,
      hint: "Stripe is verifying your details.",
    };
  }
  if (status.status !== "ready") {
    return {
      label: "Fix payout setup",
      action: "setup",
      disabled: false,
      hint: "Stripe needs more information before you can withdraw.",
    };
  }
  if (availableUsd < minWithdrawUsd) {
    return {
      label: withdraw,
      action: "withdraw",
      disabled: true,
      hint: `Minimum withdrawal is $${minWithdrawUsd.toFixed(2)} — your withdrawable balance is $${availableUsd.toFixed(2)}.`,
    };
  }
  return { label: withdraw, action: "withdraw", disabled: false, hint: null };
}

export function BalanceHero({
  totalBalanceMicro,
  withdrawableMicro,
  status,
  minWithdrawUsd,
  onWithdraw,
  onSetup,
  onOpenDashboard,
  dashboardLoading,
}: {
  totalBalanceMicro: number;
  withdrawableMicro: number;
  status: StripeStatus | null;
  minWithdrawUsd: number;
  onWithdraw: () => void;
  onSetup: () => void;
  /** Open the Stripe Express Dashboard to change the payout destination. */
  onOpenDashboard?: () => void;
  dashboardLoading?: boolean;
}) {
  const creditsMicro = totalBalanceMicro - withdrawableMicro;
  const cta = heroCta(status, withdrawableMicro / 1_000_000, minWithdrawUsd);
  return (
    <div className="relative overflow-hidden rounded-xl bg-coral text-white shadow-sm p-6 flex flex-col justify-between min-h-[220px]">
      {/* Dot texture, echoes the marketing hero. */}
      <div
        aria-hidden="true"
        className="absolute inset-0 opacity-20"
        style={{
          backgroundImage:
            "radial-gradient(rgba(255,255,255,0.35) 1px, transparent 1px)",
          backgroundSize: "14px 14px",
        }}
      />
      <div className="relative flex flex-wrap items-center justify-between gap-4">
        <div>
          <p className="text-sm text-white/70 mb-1">Current balance</p>
          <p className="text-4xl sm:text-5xl font-bold font-mono tracking-tight">
            {formatMicroDollars(totalBalanceMicro)}
          </p>
        </div>
        <div className="flex flex-col items-end gap-2">
          <button
            onClick={cta.action === "withdraw" ? onWithdraw : onSetup}
            disabled={cta.disabled}
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-white text-accent-green text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all"
          >
            {cta.label}
            <ArrowRight size={14} />
          </button>
          {cta.hint && (
            <p className="text-xs text-white/70 text-right max-w-[16rem]">
              {cta.hint}
            </p>
          )}
          {status?.status === "ready" && status.destination_last4 && (
            <div className="flex items-center gap-2 text-xs text-white/70">
              {status.destination_type === "card" ? (
                <CreditCard size={12} />
              ) : (
                <Building2 size={12} />
              )}
              <span className="font-mono">
                {status.destination_type === "card" ? "Card" : "Bank"} ••
                {status.destination_last4}
              </span>
              {onOpenDashboard && (
                <button
                  onClick={onOpenDashboard}
                  disabled={dashboardLoading}
                  title="Opens your Stripe Express Dashboard, where you can change where payouts land."
                  className="flex items-center gap-1 underline underline-offset-2 hover:text-white disabled:opacity-50 transition-colors"
                >
                  {dashboardLoading ? (
                    <Loader2 size={11} className="animate-spin" />
                  ) : (
                    <ExternalLink size={11} />
                  )}
                  {dashboardLoading ? "Opening..." : "Change"}
                </button>
              )}
            </div>
          )}
        </div>
      </div>
      <div className="relative flex flex-wrap items-end gap-x-6 gap-y-2 mt-6 font-mono">
        <div>
          <p className="text-xl font-semibold text-teal-light">
            {formatMicroDollars(withdrawableMicro)}
          </p>
          <p className="text-xs text-white/70">withdrawable</p>
        </div>
        {creditsMicro > 0 && (
          <div className="border-l border-white/20 pl-6">
            <p className="text-xl font-semibold text-gold">
              {formatMicroDollars(creditsMicro)}
            </p>
            <p className="text-xs text-white/70">credits · non-withdrawable</p>
          </div>
        )}
      </div>
    </div>
  );
}
