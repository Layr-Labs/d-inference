"use client";

// Thin orchestrator for the provider earnings page: wires auth, the earnings
// data hook, and the shared Stripe payouts state machine into the layout.
// No math, no fetch — those live in aggregate.ts / useEarningsData.ts.

import { useMemo, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { trackEvent } from "@/lib/google-analytics";
import { useToastStore } from "@/hooks/useToast";
import {
  PayoutModal,
  StripeWithdrawModal,
  WithdrawalsList,
  useStripePayouts,
} from "@/components/payouts";
import { PayoutSetupModal } from "./PayoutSetupModal";
import { useEarningsData } from "./useEarningsData";
import { perDayTotals } from "./aggregate";
import { BalanceHero } from "./BalanceHero";
import { SummaryStats } from "./SummaryStats";
import { EarningsChart } from "./EarningsChart";
import { EarningsHistory } from "./EarningsHistory";
import { ErrorState, LoadingSkeleton, SignedOutState } from "./states";

export default function EarningsContent() {
  const { ready, authenticated, login } = useAuth();
  const addToast = useToastStore((s) => s.addToast);
  const [setupOpen, setSetupOpen] = useState(false);
  const { data, loading, error, unauthorized, refetch } =
    useEarningsData(authenticated);

  // Stripe payouts state machine shared with billing.
  const payouts = useStripePayouts({
    addToast,
    enabled: authenticated,
    onAfterWithdraw: refetch,
    onWithdrawStart: (method) =>
      trackEvent("provider_withdraw_started", { surface: "provider_earnings", method }),
    onWithdrawSuccess: (method) =>
      trackEvent("provider_withdraw_succeeded", { surface: "provider_earnings", method }),
    onWithdrawError: () =>
      trackEvent("provider_withdraw_failed", { surface: "provider_earnings" }),
  });

  const earnings = useMemo(() => data?.earnings ?? [], [data]);
  const days = useMemo(() => perDayTotals(earnings), [earnings]);

  if (!authenticated) {
    return <SignedOutState ready={ready} onLogin={login} />;
  }
  if (loading) {
    return <LoadingSkeleton />;
  }
  if (error) {
    return <ErrorState error={error} unauthorized={unauthorized} onRetry={refetch} />;
  }

  const withdrawableMicro =
    data?.withdrawable_balance_micro_usd ?? data?.available_balance_micro_usd ?? 0;
  const totalBalanceMicro = data?.available_balance_micro_usd ?? 0;
  const totalMicro = data?.total_micro_usd ?? 0;
  const totalJobs = data?.count ?? 0;
  const recentCount = data?.recent_count ?? earnings.length;

  const minWithdrawUsd = (payouts.status?.min_withdraw_micro_usd ?? 1_000_000) / 1_000_000;
  const availableUsd = withdrawableMicro / 1_000_000;
  const openWithdraw = () =>
    payouts.openWithdraw(availableUsd >= minWithdrawUsd ? availableUsd.toFixed(2) : "10");

  return (
    <div className="max-w-5xl mx-auto p-6 space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-text-primary">Provider Earnings</h2>
        <p className="text-sm text-text-tertiary mt-0.5">
          Across all linked provider nodes
        </p>
      </div>

      {/* Balance hero — the CTA carries the whole payout flow (link/withdraw) */}
      <BalanceHero
        totalBalanceMicro={totalBalanceMicro}
        withdrawableMicro={withdrawableMicro}
        status={payouts.status}
        minWithdrawUsd={minWithdrawUsd}
        onWithdraw={openWithdraw}
        onSetup={() => setSetupOpen(true)}
        onOpenDashboard={payouts.openDashboard}
        dashboardLoading={payouts.dashboardLoading}
      />

      {/* Recent withdrawals (renders nothing until there are any) */}
      {payouts.withdrawals.length > 0 && (
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5 [&>div]:mt-0 [&>div]:pt-0 [&>div]:border-t-0">
          <WithdrawalsList withdrawals={payouts.withdrawals} />
        </div>
      )}

      {/* Trend + lifetime stats */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <div className="lg:col-span-2">
          <EarningsChart days={days} />
        </div>
        <SummaryStats totalMicro={totalMicro} jobs={totalJobs} />
      </div>

      <EarningsHistory
        earnings={earnings}
        totalJobs={totalJobs}
        recentCount={recentCount}
      />

      {/* Payout setup modal (link bank / finish or fix Stripe onboarding) */}
      <PayoutModal
        open={setupOpen}
        onClose={() => !payouts.onboardLoading && setSetupOpen(false)}
      >
        <PayoutSetupModal
          status={payouts.status}
          onboardLoading={payouts.onboardLoading}
          selectedCountry={payouts.selectedCountry}
          onCountryChange={payouts.setSelectedCountry}
          onOnboard={payouts.onboard}
          onUnlink={payouts.unlink}
          unlinkLoading={payouts.unlinkLoading}
        />
      </PayoutModal>

      {/* Stripe Withdraw Modal */}
      <PayoutModal
        open={payouts.withdrawOpen}
        onClose={() => !payouts.withdrawLoading && payouts.setWithdrawOpen(false)}
      >
        <StripeWithdrawModal
          status={payouts.status}
          balanceMicroUsd={withdrawableMicro}
          amount={payouts.withdrawAmount}
          method={payouts.withdrawMethod}
          loading={payouts.withdrawLoading}
          onAmountChange={payouts.setWithdrawAmount}
          onMethodChange={payouts.setWithdrawMethod}
          onConfirm={payouts.withdraw}
          onCancel={() => payouts.setWithdrawOpen(false)}
        />
      </PayoutModal>
    </div>
  );
}
