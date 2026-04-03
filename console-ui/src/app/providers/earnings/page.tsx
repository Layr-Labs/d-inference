"use client";

import { useEffect, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { Loader2, DollarSign, Briefcase, TrendingUp, Wallet } from "lucide-react";

const COORDINATOR_URL = "https://inference-test.openinnovation.dev";

interface EarningsData {
  wallet_address: string;
  balance_micro_usd: number;
  balance_usd: string;
  total_earned: string;
  total_jobs: number;
  history: { type: string; amount_micro_usd: number; timestamp: string; request_id?: string }[];
  payouts: { amount_micro_usd: number; tx_hash: string; timestamp: string }[];
}

export default function EarningsPage() {
  const { walletAddress } = useAuth();
  const [data, setData] = useState<EarningsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!walletAddress) {
      setLoading(false);
      return;
    }

    async function fetchEarnings() {
      try {
        const res = await fetch(
          `${COORDINATOR_URL}/v1/provider/earnings?wallet=${walletAddress}`
        );
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        setData(await res.json());
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    }
    fetchEarnings();
    const interval = setInterval(fetchEarnings, 30000);
    return () => clearInterval(interval);
  }, [walletAddress]);

  if (!walletAddress) {
    return (
      <div className="max-w-4xl mx-auto p-6">
        <div className="text-center py-16">
          <Wallet size={32} className="mx-auto mb-3 text-text-tertiary opacity-50" />
          <p className="text-sm text-text-tertiary">
            Connect a Solana wallet to view your provider earnings.
          </p>
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

  return (
    <div className="max-w-4xl mx-auto p-6 space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-text-primary">Provider Earnings</h2>
        <p className="text-sm text-text-tertiary mt-0.5 font-mono">
          {walletAddress.slice(0, 8)}...{walletAddress.slice(-6)}
        </p>
      </div>

      {/* Stats cards */}
      <div className="grid grid-cols-3 gap-4">
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
          <div className="flex items-center gap-2 mb-2">
            <DollarSign size={16} className="text-accent-green" />
            <p className="text-xs text-text-tertiary">Current Balance</p>
          </div>
          <p className="text-2xl font-bold text-text-primary">
            ${data?.balance_usd || "0.00"}
          </p>
        </div>
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
          <div className="flex items-center gap-2 mb-2">
            <TrendingUp size={16} className="text-accent-brand" />
            <p className="text-xs text-text-tertiary">Total Earned</p>
          </div>
          <p className="text-2xl font-bold text-text-primary">
            ${data?.total_earned || "0.00"}
          </p>
        </div>
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
          <div className="flex items-center gap-2 mb-2">
            <Briefcase size={16} className="text-accent-amber" />
            <p className="text-xs text-text-tertiary">Jobs Completed</p>
          </div>
          <p className="text-2xl font-bold text-text-primary">
            {data?.total_jobs || 0}
          </p>
        </div>
      </div>

      {/* Earnings history */}
      <div>
        <h3 className="text-sm font-semibold text-text-primary mb-3">Recent Activity</h3>
        <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
          {data?.history && data.history.length > 0 ? (
            <table className="w-full">
              <thead>
                <tr className="border-b border-border-dim">
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Type</th>
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Amount</th>
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Time</th>
                </tr>
              </thead>
              <tbody>
                {data.history.slice(0, 20).map((entry, i) => (
                  <tr key={i} className="border-b border-border-dim/50 last:border-0">
                    <td className="px-4 py-3 text-sm text-text-primary capitalize">{entry.type}</td>
                    <td className="px-4 py-3 text-sm font-mono text-accent-green">
                      +${(entry.amount_micro_usd / 1_000_000).toFixed(6)}
                    </td>
                    <td className="px-4 py-3 text-sm text-text-tertiary">
                      {new Date(entry.timestamp).toLocaleString()}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <div className="text-center py-12 text-text-tertiary">
              <p className="text-sm">No earnings activity yet</p>
            </div>
          )}
        </div>
      </div>

      {/* Payouts */}
      {data?.payouts && data.payouts.length > 0 && (
        <div>
          <h3 className="text-sm font-semibold text-text-primary mb-3">Payouts</h3>
          <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
            <table className="w-full">
              <thead>
                <tr className="border-b border-border-dim">
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Amount</th>
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Transaction</th>
                  <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Date</th>
                </tr>
              </thead>
              <tbody>
                {data.payouts.map((payout, i) => (
                  <tr key={i} className="border-b border-border-dim/50 last:border-0">
                    <td className="px-4 py-3 text-sm font-mono text-text-primary">
                      ${(payout.amount_micro_usd / 1_000_000).toFixed(2)}
                    </td>
                    <td className="px-4 py-3 text-sm font-mono text-text-tertiary">
                      {payout.tx_hash.slice(0, 12)}...
                    </td>
                    <td className="px-4 py-3 text-sm text-text-tertiary">
                      {new Date(payout.timestamp).toLocaleDateString()}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
