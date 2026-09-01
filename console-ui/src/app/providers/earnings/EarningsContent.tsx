"use client";

// Thin orchestrator for the provider earnings page: wires auth, the earnings
// data hook, and the shared Stripe payouts state machine into the layout.
// No math, no fetch — those live in aggregate.ts / useEarningsData.ts.

import { useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { microToUsd } from "@/lib/format/currency";
import { trackEvent } from "@/lib/google-analytics";
import { useToastStore } from "@/hooks/useToast";
import {
  PayoutModal,
  StripeWithdrawModal,
  WithdrawalsList,
  useStripePayouts,
} from "@/components/payouts";
import { PayoutSetupModal } from "./PayoutSetupModal";
import { EARNINGS_FIXTURE_ACTIVE, useEarningsData } from "./useEarningsData";
import { oldestRowIso, perBucketTotals, perModelSummary } from "./aggregate";
import { chartCoverageNote } from "./format";
import { BalanceHero } from "./BalanceHero";
import { SummaryStats } from "./SummaryStats";
import { ActivityFilterBar } from "./ActivityFilterBar";
import { EarningsChart } from "./EarningsChart";
import { EarningsHistory } from "./EarningsHistory";
import { ErrorState, LoadingSkeleton, SignedOutState } from "./states";

export default function EarningsContent() {
  const { ready, authenticated, login } = useAuth();
  const addToast = useToastStore((s) => s.addToast);
  const [setupOpen, setSetupOpen] = useState(false);
  // Global model filter: "" means all models. It narrows both the chart and
  // the recent-activity list. There is no time filter — the chart self-scales
  // to the span of the fetched window.
  const [filterModel, setFilterModel] = useState("");
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

  // Dev-only fixture preview skips the sign-in wall so the page can be
  // exercised locally without a Privy session.
  if (!authenticated && !EARNINGS_FIXTURE_ACTIVE) {
    return <SignedOutState ready={ready} onLogin={login} />;
  }
  if (loading) {
    return <LoadingSkeleton />;
  }
  if (error || !data) {
    return (
      <ErrorState
        error={error ?? "No data returned."}
        unauthorized={unauthorized}
        onRetry={refetch}
      />
    );
  }

  const earnings = data.earnings;
  const allModels = perModelSummary(earnings).map((s) => s.model);
  // Fall back to "all" if a refetch drops the selected model from the data.
  const activeModel = allModels.includes(filterModel) ? filterModel : "";
  const filteredEarnings = activeModel
    ? earnings.filter((e) => e.model === activeModel)
    : earnings;
  const series = perBucketTotals(filteredEarnings);
  // Older coordinators may omit the withdrawable split; treat it all as withdrawable.
  const withdrawableMicro =
    data.withdrawable_balance_micro_usd ?? data.available_balance_micro_usd;
  const totalBalanceMicro = data.available_balance_micro_usd;
  const totalMicro = data.total_micro_usd;
  const totalJobs = data.count;
  const recentCount = data.recent_count ?? earnings.length;
  // Honest chart: when the server truncated the history window, say so on
  // the card instead of implying full lifetime coverage.
  const coverageNote = chartCoverageNote(
    totalJobs,
    recentCount,
    oldestRowIso(earnings),
  );

  const minWithdrawUsd = microToUsd(payouts.status?.min_withdraw_micro_usd ?? 1_000_000);
  const availableUsd = microToUsd(withdrawableMicro);
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

      {/* Lifetime KPI cards (unfiltered — server-side totals) */}
      <SummaryStats totalMicro={totalMicro} jobs={totalJobs} />

      {/* Balance hero — the CTA carries the whole payout flow (link/withdraw) */}
      <BalanceHero
        totalBalanceMicro={totalBalanceMicro}
        withdrawableMicro={withdrawableMicro}
        status={payouts.status}
        statusFailed={payouts.statusError}
        minWithdrawUsd={minWithdrawUsd}
        onWithdraw={openWithdraw}
        onSetup={() => setSetupOpen(true)}
        onRetryStatus={() => {
          payouts.reload(false);
        }}
        onOpenDashboard={payouts.openDashboard}
        dashboardLoading={payouts.dashboardLoading}
      />

      {/* Recent withdrawals (renders nothing until there are any) */}
      {payouts.withdrawals.length > 0 && (
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
          <WithdrawalsList withdrawals={payouts.withdrawals} flush />
        </div>
      )}

      {/* Global model filter: drives both the chart and the activity list */}
      <ActivityFilterBar
        models={allModels}
        selectedModel={activeModel}
        onSelectModel={setFilterModel}
      />

      {/* Earnings + demand trend, bucketed to fit the fetched window's span */}
      <EarningsChart
        days={series.buckets}
        granularity={series.granularity}
        note={coverageNote}
      />

      <EarningsHistory
        earnings={filteredEarnings}
        totalJobs={totalJobs}
        recentCount={recentCount}
        filteredOut={earnings.length > 0}
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
