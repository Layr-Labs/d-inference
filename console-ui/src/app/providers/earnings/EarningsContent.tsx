"use client";

import { useState, useCallback } from "react";
import { useAuth } from "@/hooks/useAuth";
import { trackEvent } from "@/lib/google-analytics";
import { useToastStore } from "@/hooks/useToast";
import { useVisiblePolling } from "@/hooks/useVisiblePolling";
import { STORAGE_KEYS } from "@/lib/constants";
import {
  Loader2,
  DollarSign,
  Briefcase,
  TrendingUp,
  LogIn,
  ArrowDownToLine,
} from "lucide-react";
import {
  PayoutModal,
  StripePayoutsCard,
  StripeWithdrawModal,
  useStripePayouts,
} from "@/components/payouts";

interface Earning {
  id: number;
  provider_id: string;
  provider_key: string;
  job_id: string;
  model: string;
  amount_micro_usd: number;
  prompt_tokens: number;
  completion_tokens: number;
  created_at: string;
}

interface EarningsResponse {
  account_id: string;
  earnings: Earning[];
  total_micro_usd: number;
  total_usd: string;
  count: number;
  recent_count: number;
  history_limit: number;
  available_balance_micro_usd: number;
  available_balance_usd: string;
  withdrawable_balance_micro_usd: number;
  withdrawable_balance_usd: string;
}

export default function EarningsContent() {
  const { ready, authenticated, login, getAccessToken } = useAuth();
  const addToast = useToastStore((s) => s.addToast);
  const [data, setData] = useState<EarningsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const getAuthHeaders = useCallback(async () => {
    const accessToken = await getAccessToken().catch(() => null);
    if (accessToken) {
      return { Authorization: `Bearer ${accessToken}` };
    }

    const apiKey = localStorage.getItem(STORAGE_KEYS.apiKey) || "";
    return apiKey ? { Authorization: `Bearer ${apiKey}` } : {};
  }, [getAccessToken]);

  const fetchEarnings = useCallback(async () => {
    setError(null);
    try {
      // Same-origin proxy (perf F9): no cross-origin preflight, coordinator URL
      // resolved server-side.
      const headers = await getAuthHeaders();
      const res = await fetch(`/api/me/earnings?limit=100`, { headers });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setData(await res.json());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [getAuthHeaders]);

  // Stripe payouts state machine shared with billing.
  const payouts = useStripePayouts({
    addToast,
    enabled: authenticated,
    onAfterWithdraw: fetchEarnings,
    onWithdrawStart: (method) =>
      trackEvent("provider_withdraw_started", { surface: "provider_earnings", method }),
    onWithdrawSuccess: (method) =>
      trackEvent("provider_withdraw_succeeded", { surface: "provider_earnings", method }),
    onWithdrawError: () =>
      trackEvent("provider_withdraw_failed", { surface: "provider_earnings" }),
  });

  // Poll earnings only while the tab is visible (perf F6).
  useVisiblePolling(fetchEarnings, 30_000, authenticated);

  if (!authenticated) {
    return (
      <div className="max-w-4xl mx-auto p-6">
        <div className="text-center py-16">
          <LogIn size={32} className="mx-auto mb-3 text-text-tertiary opacity-50" />
          <p className="text-sm text-text-tertiary mb-4">
            Sign in to view your provider earnings.
          </p>
          <button
            onClick={() => {
              trackEvent("login_cta_clicked", {
                source: "provider_earnings_empty_state",
              });
              login();
            }}
            disabled={!ready}
            className="px-4 py-2 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {ready ? "Sign In" : "Loading..."}
          </button>
        </div>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 size={24} className="animate-spin text-accent-brand" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="max-w-4xl mx-auto p-6">
        <p className="text-accent-red text-sm">Failed to load earnings: {error}</p>
      </div>
    );
  }

  const totalEarned = data?.total_usd || "0.000000";
  const withdrawableBalanceMicro = data?.withdrawable_balance_micro_usd ?? data?.available_balance_micro_usd ?? 0;
  const totalBalance = data?.available_balance_micro_usd || 0;
  const creditsBalance = totalBalance - withdrawableBalanceMicro;
  const totalJobs = data?.count || 0;
  const recentCount = data?.recent_count ?? data?.earnings.length ?? 0;

  const minWithdrawUsd = (payouts.status?.min_withdraw_micro_usd ?? 1_000_000) / 1_000_000;
  const availableUsd = withdrawableBalanceMicro / 1_000_000;

  return (
    <div className="max-w-4xl mx-auto p-6 space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-text-primary">Provider Earnings</h2>
        <p className="text-sm text-text-tertiary mt-0.5">
          Across all linked provider nodes
        </p>
      </div>

      {/* Stats cards */}
      <div className="grid grid-cols-3 gap-4">
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
          <div className="flex items-center gap-2 mb-2">
            <DollarSign size={16} className="text-accent-green" />
            <p className="text-xs text-text-tertiary">Total Earned</p>
          </div>
          <p className="text-2xl font-bold text-text-primary">
            ${totalEarned}
          </p>
        </div>
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
          <div className="flex items-center gap-2 mb-2">
            <Briefcase size={16} className="text-accent-amber" />
            <p className="text-xs text-text-tertiary">Jobs Completed</p>
          </div>
          <p className="text-2xl font-bold text-text-primary">
            {totalJobs}
          </p>
        </div>
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
          <div className="flex items-center gap-2 mb-2">
            <TrendingUp size={16} className="text-accent-brand" />
            <p className="text-xs text-text-tertiary">Avg per Job</p>
          </div>
          <p className="text-2xl font-bold text-text-primary">
            ${totalJobs > 0 ? (parseFloat(totalEarned) / totalJobs).toFixed(6) : "0.00"}
          </p>
        </div>
      </div>

      {/* Withdraw Earnings (Stripe Connect) */}
      <StripePayoutsCard
        status={payouts.status}
        withdrawals={payouts.withdrawals}
        balanceMicroUsd={withdrawableBalanceMicro}
        onboardLoading={payouts.onboardLoading}
        selectedCountry={payouts.selectedCountry}
        onCountryChange={payouts.setSelectedCountry}
        onOnboard={payouts.onboard}
        onUnlink={payouts.unlink}
        unlinkLoading={payouts.unlinkLoading}
        onAutoWithdrawChange={payouts.setAutoWithdraw}
        autoWithdrawLoading={payouts.autoWithdrawLoading}
        onOpenWithdraw={() =>
          payouts.openWithdraw(availableUsd >= minWithdrawUsd ? availableUsd.toFixed(2) : "10")
        }
        title="Withdraw Earnings"
        icon={<ArrowDownToLine size={16} className="text-teal" />}
        noun="earnings"
        className="rounded-xl bg-bg-secondary shadow-sm p-5"
      >
        {/* Withdrawable earnings display */}
        <div className="flex items-baseline gap-1 mb-1 mt-1">
          <span className="text-3xl font-bold text-text-primary font-mono tracking-tight">
            ${(totalBalance / 1_000_000).toFixed(2)}
          </span>
          <span className="text-sm text-text-tertiary font-mono">balance</span>
        </div>
        <div className="flex gap-4 mb-4 text-xs font-mono text-text-tertiary">
          <span>${(withdrawableBalanceMicro / 1_000_000).toFixed(2)} withdrawable earnings</span>
          {creditsBalance > 0 && (
            <span>${(creditsBalance / 1_000_000).toFixed(2)} credits (non-withdrawable)</span>
          )}
        </div>
      </StripePayoutsCard>

      {/* Earnings history */}
      <div>
        <h3 className="text-sm font-semibold text-text-primary mb-3">Recent Activity</h3>
        {totalJobs > recentCount && (
          <p className="text-xs text-text-tertiary mb-3">
            Showing the latest {recentCount} of {totalJobs} payouts.
          </p>
        )}
        <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
          {data?.earnings && data.earnings.length > 0 ? (
            <table className="w-full">
              <thead>
                <tr className="border-b border-border-dim">
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Model</th>
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Earned</th>
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Tokens</th>
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Time</th>
                </tr>
              </thead>
              <tbody>
                {data.earnings.map((e) => (
                  <tr key={e.id} className="border-b border-border-dim/50 last:border-0">
                    <td className="px-4 py-3 text-sm font-mono text-text-primary">
                      {e.model.split("/").pop()}
                    </td>
                    <td className="px-4 py-3 text-sm font-mono text-accent-green">
                      +${(e.amount_micro_usd / 1_000_000).toFixed(6)}
                    </td>
                    <td className="px-4 py-3 text-sm text-text-tertiary">
                      {e.prompt_tokens + e.completion_tokens} ({e.completion_tokens} out)
                    </td>
                    <td className="px-4 py-3 text-sm text-text-tertiary">
                      {new Date(e.created_at).toLocaleString()}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <div className="text-center py-12 text-text-tertiary">
              <p className="text-sm">No earnings activity yet</p>
              <p className="text-xs mt-1">Earnings appear here when your provider serves inference requests</p>
            </div>
          )}
        </div>
      </div>

      {/* Stripe Withdraw Modal */}
      <PayoutModal open={payouts.withdrawOpen} onClose={() => !payouts.withdrawLoading && payouts.setWithdrawOpen(false)}>
        <StripeWithdrawModal
          status={payouts.status}
          balanceMicroUsd={withdrawableBalanceMicro}
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
