"use client";

import { useEffect, useState, useCallback } from "react";
import { useToastStore } from "@/hooks/useToast";
import { useAuth } from "@/hooks/useAuth";
import { TopBar } from "@/components/TopBar";
import {
  fetchBalance,
  fetchUsage,
  createStripeCheckout,
  redeemInviteCode,
  type BalanceResponse,
  type UsageEntry,
} from "@/lib/api";
import { trackEvent } from "@/lib/google-analytics";
import {
  Clock,
  Loader2,
  DollarSign,
  TrendingUp,
  Ticket,
  Check,
  CreditCard,
  Building2,
} from "lucide-react";
import { UsageChart } from "@/components/UsageChart";
import {
  PayoutModal,
  StripePayoutsCard,
  StripeWithdrawModal,
  useStripePayouts,
} from "@/components/payouts";

export default function BillingContent() {
  const addToast = useToastStore((s) => s.addToast);
  const { email } = useAuth();
  const [balance, setBalance] = useState<BalanceResponse | null>(null);
  const [usage, setUsage] = useState<UsageEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [buyOpen, setBuyOpen] = useState(false);
  const [buyAmount, setBuyAmount] = useState("10");
  const [actionLoading, setActionLoading] = useState(false);
  const [inviteCode, setInviteCode] = useState("");
  const [inviteLoading, setInviteLoading] = useState(false);
  const [inviteSuccess, setInviteSuccess] = useState("");
  const [sortField, setSortField] = useState<"timestamp" | "cost_micro_usd">(
    "timestamp"
  );
  const [sortAsc, setSortAsc] = useState(false);

  const loadData = useCallback(async () => {
    setLoading(true);
    try {
      const [b, u] = await Promise.all([
        fetchBalance(),
        fetchUsage(),
      ]);
      setBalance(b);
      setUsage(u);
    } catch (e) {
      addToast(`Failed to load billing data: ${(e as Error).message}`);
    }
    setLoading(false);
  }, [addToast]);

  // Stripe payouts state machine (status/onboard/withdraw) shared with earnings.
  const payouts = useStripePayouts({ addToast, onAfterWithdraw: loadData });

  useEffect(() => {
    loadData();
  }, [loadData]);

  // Detect Stripe Checkout (buy credits) success redirect.
  useEffect(() => {
    if (typeof window === "undefined") return;
    const params = new URLSearchParams(window.location.search);
    if (params.get("stripe_checkout_success") === "1") {
      addToast("Payment successful!", "success");
      loadData();
      const url = new URL(window.location.href);
      url.searchParams.delete("stripe_checkout_success");
      window.history.replaceState({}, "", url.toString());
    }
  }, [addToast, loadData]);

  const handleStripeCheckout = async () => {
    setActionLoading(true);
    trackEvent("billing_buy_credits_submitted", {
      amount_usd: Number(buyAmount),
    });
    try {
      const resp = await createStripeCheckout(buyAmount, email || undefined);
      trackEvent("billing_buy_credits_redirected", {
        amount_usd: Number(buyAmount),
      });
      window.location.href = resp.url;
    } catch (e) {
      trackEvent("billing_buy_credits_failed", {
        reason: "checkout_error",
      });
      addToast(`${(e as Error).message}`);
      setActionLoading(false);
    }
  };

  const handleRedeem = async () => {
    const code = inviteCode.trim().toUpperCase();
    if (!code) return;
    setInviteLoading(true);
    setInviteSuccess("");
    trackEvent("invite_redeem_submitted", {
      surface: "billing_page",
    });
    try {
      const result = await redeemInviteCode(code);
      trackEvent("invite_redeem_succeeded", {
        surface: "billing_page",
        credited_usd: result.credited_usd,
      });
      setInviteSuccess(`$${result.credited_usd} credited to your account`);
      setInviteCode("");
      loadData();
    } catch (e) {
      trackEvent("invite_redeem_failed", {
        surface: "billing_page",
      });
      addToast(`${(e as Error).message}`);
    }
    setInviteLoading(false);
  };

  const sortedUsage = [...usage].sort((a, b) => {
    const aVal = sortField === "timestamp" ? new Date(a.timestamp).getTime() : a.cost_micro_usd;
    const bVal = sortField === "timestamp" ? new Date(b.timestamp).getTime() : b.cost_micro_usd;
    return sortAsc ? aVal - bVal : bVal - aVal;
  });

  const totalSpent = usage.reduce((sum, u) => sum + u.cost_micro_usd, 0);
  const totalTokens = usage.reduce(
    (sum, u) => sum + u.prompt_tokens + u.completion_tokens,
    0
  );

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Billing" />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-4xl mx-auto px-3 sm:px-6 py-6 sm:py-8 space-y-8">
          {/* Balance Card */}
          <div className="relative overflow-hidden rounded-2xl border border-border-dim bg-bg-white p-6 sm:p-8 shadow-md">
            <div className="relative">
              <p className="text-xs font-mono text-text-tertiary uppercase tracking-widest mb-2">
                Balance
              </p>
              {loading ? (
                <div className="flex items-center gap-2 text-text-tertiary">
                  <Loader2 size={16} className="animate-spin" />
                  <span className="text-sm">Loading...</span>
                </div>
              ) : (
                <>
                  <div className="flex items-baseline gap-1 mb-2">
                    <span className="text-4xl font-bold text-text-primary font-mono tracking-tight">
                      ${Number(balance?.balance_usd ?? 0).toFixed(2)}
                    </span>
                    <span className="text-sm text-text-tertiary font-mono">
                      USD
                    </span>
                  </div>
                  <div className="flex gap-4 mb-4 text-xs font-mono text-text-tertiary">
                    <span>${(((balance?.balance_micro_usd ?? 0) - (balance?.withdrawable_micro_usd ?? 0)) / 1_000_000).toFixed(2)} credits</span>
                    <span>${((balance?.withdrawable_micro_usd ?? 0) / 1_000_000).toFixed(2)} earnings</span>
                  </div>
                </>
              )}

              <button
                onClick={() => setBuyOpen(true)}
                className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-coral border-2 border-ink text-white text-sm font-bold hover:opacity-90 transition-all"
              >
                <CreditCard size={14} />
                Buy Credits
              </button>
            </div>
          </div>

          {/* Invite Code Redemption */}
          <div className="rounded-2xl border border-border-dim bg-bg-white p-6 shadow-md">
            <div className="flex items-center gap-2 mb-4">
              <Ticket size={16} className="text-gold" />
              <h3 className="text-sm font-semibold text-text-primary">Invite Code</h3>
            </div>
            <div className="flex gap-3">
              <input
                type="text"
                value={inviteCode}
                onChange={(e) => {
                  setInviteSuccess("");
                  const raw = e.target.value.replace(/[^A-Za-z0-9-]/g, "").toUpperCase();
                  setInviteCode(raw);
                }}
                placeholder="INV-XXXXXXXX"
                maxLength={20}
                className="flex-1 bg-bg-primary border-2 border-border-dim rounded-lg px-4 py-2.5 text-text-primary font-mono text-sm tracking-wider outline-none focus:border-coral transition-colors placeholder:text-text-tertiary/50"
                onKeyDown={(e) => e.key === "Enter" && handleRedeem()}
              />
              <button
                onClick={handleRedeem}
                disabled={inviteLoading || !inviteCode.trim()}
                className="px-5 py-2.5 rounded-lg bg-coral border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all flex items-center gap-2"
              >
                {inviteLoading ? (
                  <Loader2 size={14} className="animate-spin" />
                ) : (
                  <Ticket size={14} />
                )}
                Redeem
              </button>
            </div>
            {inviteSuccess && (
              <div className="mt-3 flex items-center gap-2 text-sm text-teal font-semibold">
                <Check size={14} />
                {inviteSuccess}
              </div>
            )}
          </div>

          {/* Withdraw to Bank (Stripe Connect Express) */}
          <StripePayoutsCard
            status={payouts.status}
            withdrawals={payouts.withdrawals}
            balanceMicroUsd={balance?.balance_micro_usd ?? 0}
            onboardLoading={payouts.onboardLoading}
            selectedCountry={payouts.selectedCountry}
            onCountryChange={payouts.setSelectedCountry}
            onOnboard={payouts.onboard}
            onUnlink={payouts.unlink}
            unlinkLoading={payouts.unlinkLoading}
            onOpenWithdraw={() => payouts.openWithdraw("10")}
            title="Withdraw to Bank"
            icon={<Building2 size={16} className="text-teal" />}
            noun="credits"
            className="rounded-2xl border border-border-dim bg-bg-white p-6 shadow-md"
          />

          {/* Stats row */}
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 sm:gap-4">
            {[
              {
                icon: DollarSign,
                label: "Total Spent",
                value: `$${(totalSpent / 1_000_000).toFixed(4)}`,
                color: "text-coral",
              },
              {
                icon: TrendingUp,
                label: "Total Tokens",
                value: totalTokens.toLocaleString(),
                color: "text-teal",
              },
              {
                icon: Clock,
                label: "Requests",
                value: usage.length.toString(),
                color: "text-gold",
              },
            ].map(({ icon: Icon, label, value, color }) => (
              <div
                key={label}
                className="rounded-xl bg-bg-white p-4 border-2 border-border-dim shadow-sm"
              >
                <div className="flex items-center gap-2 mb-2">
                  <Icon size={13} className={color} />
                  <span className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
                    {label}
                  </span>
                </div>
                <p className="text-lg font-mono font-semibold text-text-primary">
                  {value}
                </p>
              </div>
            ))}
          </div>

          {/* Usage Chart */}
          <UsageChart usage={usage} />

          {/* Usage Table */}
          <div className="rounded-xl bg-bg-white border border-border-dim overflow-hidden shadow-md">
            <div className="px-5 py-4 border-b border-border-subtle flex items-center gap-2">
              <Clock size={14} className="text-text-tertiary" />
              <h3 className="text-sm font-semibold text-text-primary">
                Usage History
              </h3>
            </div>

            {usage.length === 0 ? (
              <div className="px-5 py-12 text-center text-sm text-text-tertiary">
                No usage history yet. Start a chat to see requests here.
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border-subtle">
                      {[
                        { key: "timestamp", label: "Time" },
                        { key: "model", label: "Model" },
                        { key: "tokens", label: "Tokens" },
                        { key: "cost_micro_usd", label: "Cost" },
                      ].map(({ key, label }) => (
                        <th
                          key={key}
                          onClick={() => {
                            if (key === "timestamp" || key === "cost_micro_usd") {
                              if (sortField === key) setSortAsc(!sortAsc);
                              else {
                                setSortField(key as typeof sortField);
                                setSortAsc(false);
                              }
                            }
                          }}
                          className={`px-3 sm:px-5 py-3 text-left text-xs font-mono text-text-tertiary uppercase tracking-wider ${
                            key === "timestamp" || key === "cost_micro_usd"
                              ? "cursor-pointer hover:text-text-secondary"
                              : ""
                          }`}
                        >
                          {label}
                          {sortField === key && (sortAsc ? " ↑" : " ↓")}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {sortedUsage.map((entry) => (
                      <tr
                        key={entry.request_id}
                        className="border-b border-border-subtle/50 hover:bg-bg-hover/50 transition-colors"
                      >
                        <td className="px-3 sm:px-5 py-3 font-mono text-xs text-text-secondary">
                          {new Date(entry.timestamp).toLocaleString()}
                        </td>
                        <td className="px-3 sm:px-5 py-3">
                          <span className="font-mono text-xs text-coral">
                            {entry.model.split("/").pop()}
                          </span>
                        </td>
                        <td className="px-3 sm:px-5 py-3 font-mono text-xs text-text-secondary">
                          {entry.prompt_tokens + entry.completion_tokens}
                          <span className="text-text-tertiary ml-1">
                            ({entry.prompt_tokens}p / {entry.completion_tokens}c)
                          </span>
                        </td>
                        <td className="px-3 sm:px-5 py-3 font-mono text-xs text-teal">
                          ${(entry.cost_micro_usd / 1_000_000).toFixed(6)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Buy Credits Modal */}
      <PayoutModal open={buyOpen} onClose={() => setBuyOpen(false)}>
        <div className="px-6 pb-6">
          <h3 className="text-2xl font-semibold text-ink mb-2">
            Buy Credits
          </h3>
          <p className="text-sm text-text-secondary mb-4">
            Credits are used to pay for inference requests.
          </p>

          <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
            Amount (USD)
          </label>
          <div className="flex items-center gap-2 mb-4">
            <span className="text-text-tertiary text-lg">$</span>
            <input
              type="number"
              value={buyAmount}
              onChange={(e) => setBuyAmount(e.target.value)}
              className="flex-1 bg-bg-primary border border-border-dim rounded-lg px-4 py-3 text-text-primary font-mono text-lg outline-none focus:border-coral transition-colors"
              min="1"
              max="20"
              step="1"
            />
          </div>
          {parseFloat(buyAmount) > 20 && (
            <p className="text-xs text-red-500 mb-2">Maximum deposit is $20</p>
          )}
          <div className="flex gap-2 mb-6">
            {[5, 10, 15, 20].map((amt) => (
              <button
                key={amt}
                onClick={() => setBuyAmount(String(amt))}
                className={`flex-1 py-2 rounded-lg border-2 text-sm font-mono font-bold transition-all ${
                  buyAmount === String(amt)
                    ? "bg-coral/15 border-coral text-coral"
                    : "bg-bg-primary border-border-dim text-text-secondary hover:border-coral/30 hover:text-coral"
                }`}
              >
                ${amt}
              </button>
            ))}
          </div>
          <button
            onClick={handleStripeCheckout}
            disabled={actionLoading || !buyAmount || parseFloat(buyAmount) <= 0 || parseFloat(buyAmount) > 20}
            className="w-full py-3 rounded-lg bg-coral border border-border-dim text-white font-bold text-sm
                       hover:opacity-90
                       disabled:opacity-50
                       transition-all flex items-center justify-center gap-2"
          >
            {actionLoading && <Loader2 size={14} className="animate-spin" />}
            {actionLoading ? "Redirecting..." : "Continue"}
          </button>
          <p className="mt-4 text-xs text-text-tertiary text-center">
            Powered by Stripe. Secure card payment.
          </p>
        </div>
      </PayoutModal>

      {/* Stripe Withdraw Modal */}
      <PayoutModal open={payouts.withdrawOpen} onClose={() => !payouts.withdrawLoading && payouts.setWithdrawOpen(false)}>
        <StripeWithdrawModal
          status={payouts.status}
          balanceMicroUsd={balance?.balance_micro_usd ?? 0}
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
