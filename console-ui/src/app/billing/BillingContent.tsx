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
  fetchStripeStatus,
  startStripeOnboarding,
  withdrawStripe,
  fetchStripeWithdrawals,
  computeStripeFeeUsd,
  type BalanceResponse,
  type UsageEntry,
  type StripeStatus,
  type StripeWithdrawal,
} from "@/lib/api";
import { trackEvent } from "@/lib/google-analytics";
import {
  Clock,
  X,
  Loader2,
  DollarSign,
  TrendingUp,
  Ticket,
  Check,
  CreditCard,
  Building2,
  Zap,
  AlertCircle,
  ArrowDownToLine,
} from "lucide-react";
import { UsageChart } from "@/components/UsageChart";

function Modal({
  open,
  onClose,
  children,
}: {
  open: boolean;
  onClose: () => void;
  children: React.ReactNode;
}) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
      <div className="bg-bg-white border border-border-dim rounded-xl w-full max-w-md mx-2 sm:mx-4 shadow-lg">
        <div className="flex justify-end p-3">
          <button
            onClick={onClose}
            className="p-1 rounded hover:bg-bg-hover text-text-tertiary"
          >
            <X size={16} />
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

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

  // Stripe Payouts state.
  const [stripeStatus, setStripeStatus] = useState<StripeStatus | null>(null);
  const [stripeWithdrawals, setStripeWithdrawals] = useState<StripeWithdrawal[]>([]);
  const [stripeOnboardLoading, setStripeOnboardLoading] = useState(false);
  const [withdrawOpen, setWithdrawOpen] = useState(false);
  const [withdrawAmount, setWithdrawAmount] = useState("10");
  const [withdrawMethod, setWithdrawMethod] = useState<"standard" | "instant">("standard");
  const [withdrawLoading, setWithdrawLoading] = useState(false);

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

  // Stripe payouts data loads independently — we don't want a misconfigured
  // coordinator to block the rest of the billing page.
  const loadStripe = useCallback(async (refresh = false) => {
    try {
      const [s, wds] = await Promise.all([
        fetchStripeStatus(refresh),
        fetchStripeWithdrawals(20).catch(() => [] as StripeWithdrawal[]),
      ]);
      setStripeStatus(s);
      setStripeWithdrawals(wds);
    } catch (e) {
      // Silent — Stripe Payouts is optional infrastructure.
      console.warn("stripe status fetch failed:", (e as Error).message);
    }
  }, []);

  useEffect(() => {
    loadData();
  }, [loadData]);

  // Refresh Stripe status on mount; if the user just came back from the
  // Stripe-hosted onboarding flow (return URL adds ?stripe_return=1) we hit
  // ?refresh=1 so the coordinator pulls the latest snapshot from Stripe
  // before the webhook arrives.
  useEffect(() => {
    const params = typeof window !== "undefined" ? new URLSearchParams(window.location.search) : null;
    const justReturned = params?.get("stripe_return") === "1";
    loadStripe(justReturned);
    if (justReturned) {
      addToast("Stripe onboarding complete — verifying...", "success");
      // Strip the query param so a refresh doesn't re-trigger the toast.
      const url = new URL(window.location.href);
      url.searchParams.delete("stripe_return");
      window.history.replaceState({}, "", url.toString());
    }
  }, [loadStripe, addToast]);

  // Detect Stripe Checkout success redirect
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

  const handleStripeOnboard = async () => {
    setStripeOnboardLoading(true);
    try {
      // We pass the current page (with ?stripe_return=1) as the return URL so
      // the user lands back on Billing after KYC.
      const returnURL = typeof window !== "undefined"
        ? `${window.location.origin}${window.location.pathname}?stripe_return=1`
        : undefined;
      const resp = await startStripeOnboarding(returnURL);
      window.location.href = resp.url;
    } catch (e) {
      addToast(`Stripe onboarding failed: ${(e as Error).message}`);
      setStripeOnboardLoading(false);
    }
  };

  const handleStripeWithdraw = async () => {
    setWithdrawLoading(true);
    try {
      const resp = await withdrawStripe(withdrawAmount, withdrawMethod);
      addToast(`Withdrawal submitted — ${resp.eta || "processing"}`, "success");
      setWithdrawOpen(false);
      // Reload balance + history.
      await Promise.all([loadData(), loadStripe(false)]);
    } catch (e) {
      addToast(`${(e as Error).message}`);
    }
    setWithdrawLoading(false);
  };

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
            status={stripeStatus}
            withdrawals={stripeWithdrawals}
            balanceMicroUsd={balance?.balance_micro_usd ?? 0}
            onboardLoading={stripeOnboardLoading}
            onOnboard={handleStripeOnboard}
            onOpenWithdraw={() => {
              setWithdrawAmount("10");
              setWithdrawMethod(stripeStatus?.instant_eligible ? "instant" : "standard");
              setWithdrawOpen(true);
            }}
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
      <Modal open={buyOpen} onClose={() => setBuyOpen(false)}>
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
      </Modal>

      {/* Stripe Withdraw Modal */}
      <Modal open={withdrawOpen} onClose={() => !withdrawLoading && setWithdrawOpen(false)}>
        <StripeWithdrawModal
          status={stripeStatus}
          balanceMicroUsd={balance?.balance_micro_usd ?? 0}
          amount={withdrawAmount}
          method={withdrawMethod}
          loading={withdrawLoading}
          onAmountChange={setWithdrawAmount}
          onMethodChange={setWithdrawMethod}
          onConfirm={handleStripeWithdraw}
          onCancel={() => setWithdrawOpen(false)}
        />
      </Modal>
    </div>
  );
}

// --- Stripe Payouts components ---

function StripePayoutsCard({
  status,
  withdrawals,
  balanceMicroUsd,
  onboardLoading,
  onOnboard,
  onOpenWithdraw,
}: {
  status: StripeStatus | null;
  withdrawals: StripeWithdrawal[];
  balanceMicroUsd: number;
  onboardLoading: boolean;
  onOnboard: () => void;
  onOpenWithdraw: () => void;
}) {
  // Stripe payouts not configured on this coordinator — hide the card entirely.
  if (status && !status.configured) return null;

  const ready = status?.status === "ready";
  const restricted = status?.status === "restricted";
  const rejected = status?.status === "rejected";
  const pending = status?.status === "pending";
  const balanceUsd = balanceMicroUsd / 1_000_000;
  const minWithdrawUsd = (status?.min_withdraw_micro_usd ?? 1_000_000) / 1_000_000;
  const canWithdraw = ready && balanceUsd >= minWithdrawUsd;

  return (
    <div className="rounded-2xl border border-border-dim bg-bg-white p-6 shadow-md">
      <div className="flex items-center gap-2 mb-4">
        <Building2 size={16} className="text-teal" />
        <h3 className="text-sm font-semibold text-text-primary">Withdraw to Bank</h3>
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

      {!status?.has_account ? (
        <>
          <p className="text-sm text-text-secondary mb-4 leading-relaxed">
            Link a bank account or debit card via Stripe to withdraw your credits.
            Stripe handles identity verification — onboarding takes about 2 minutes.
          </p>
          <button
            onClick={onOnboard}
            disabled={onboardLoading}
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 transition-all"
          >
            {onboardLoading ? <Loader2 size={14} className="animate-spin" /> : <Building2 size={14} />}
            {onboardLoading ? "Redirecting..." : "Link bank via Stripe"}
          </button>
        </>
      ) : ready ? (
        <>
          <div className="rounded-lg bg-bg-primary border border-border-dim p-3 mb-4 flex items-center justify-between">
            <div className="flex items-center gap-2 text-sm text-text-secondary">
              {status.destination_type === "card" ? (
                <CreditCard size={14} className="text-teal" />
              ) : (
                <Building2 size={14} className="text-teal" />
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
            className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all"
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
          <p className="text-sm text-text-secondary mb-4 leading-relaxed flex items-start gap-2">
            <AlertCircle size={14} className="text-coral mt-0.5 flex-shrink-0" />
            {restricted
              ? "Stripe needs more information to enable payouts on your account."
              : rejected
              ? "Stripe has disabled payouts on this account. Contact support."
              : "Finish linking your account on Stripe to enable withdrawals."}
          </p>
          {!rejected && (
            <button
              onClick={onOnboard}
              disabled={onboardLoading}
              className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 transition-all"
            >
              {onboardLoading ? <Loader2 size={14} className="animate-spin" /> : <Building2 size={14} />}
              {onboardLoading ? "Redirecting..." : restricted ? "Provide more info" : "Continue setup"}
            </button>
          )}
        </>
      )}

      {withdrawals.length > 0 && (
        <div className="mt-5 pt-5 border-t border-border-subtle">
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
            Recent withdrawals
          </p>
          <div className="space-y-2">
            {withdrawals.slice(0, 5).map((w) => (
              <div key={w.id} className="flex items-center justify-between text-sm">
                <div className="flex items-center gap-2">
                  {w.status === "paid" ? (
                    <Check size={12} className="text-teal" />
                  ) : w.status === "failed" ? (
                    <X size={12} className="text-coral" />
                  ) : (
                    <Clock size={12} className="text-gold" />
                  )}
                  <span className="font-mono text-text-secondary">
                    ${(w.net_micro_usd / 1_000_000).toFixed(2)}
                  </span>
                  <span className="text-[10px] font-mono uppercase text-text-tertiary">
                    {w.method}
                  </span>
                </div>
                <span className={`text-xs font-mono ${
                  w.status === "paid" ? "text-teal" :
                  w.status === "failed" ? "text-coral" :
                  "text-text-tertiary"
                }`}>
                  {w.status}
                  {w.refunded ? " (refunded)" : ""}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function StripeWithdrawModal({
  status,
  balanceMicroUsd,
  amount,
  method,
  loading,
  onAmountChange,
  onMethodChange,
  onConfirm,
  onCancel,
}: {
  status: StripeStatus | null;
  balanceMicroUsd: number;
  amount: string;
  method: "standard" | "instant";
  loading: boolean;
  onAmountChange: (v: string) => void;
  onMethodChange: (m: "standard" | "instant") => void;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const amountNum = parseFloat(amount) || 0;
  const balanceUsd = balanceMicroUsd / 1_000_000;
  const minWithdrawUsd = (status?.min_withdraw_micro_usd ?? 1_000_000) / 1_000_000;
  const instantBps = status?.instant_fee_bps ?? 150;
  const instantMinUsd = status?.instant_fee_min_usd ?? 0.5;
  const fee = computeStripeFeeUsd(amountNum, method, instantBps, instantMinUsd);
  const net = Math.max(0, amountNum - fee);

  const tooSmall = amountNum > 0 && amountNum < minWithdrawUsd;
  const tooLarge = amountNum > balanceUsd;
  const valid = amountNum >= minWithdrawUsd && !tooLarge;

  return (
    <div className="px-6 pb-6">
      <h3 className="text-2xl font-semibold text-ink mb-2">Withdraw to {status?.destination_type === "card" ? "card" : "bank"}</h3>
      <p className="text-sm text-text-secondary mb-4">
        Funds go to {status?.destination_type === "card" ? "your linked card" : "your linked bank account"} ••{status?.destination_last4}.
      </p>

      <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
        Amount (USD)
      </label>
      <div className="flex items-center gap-2 mb-3">
        <span className="text-text-tertiary text-lg">$</span>
        <input
          type="number"
          value={amount}
          onChange={(e) => onAmountChange(e.target.value)}
          className="flex-1 bg-bg-primary border border-border-dim rounded-lg px-4 py-3 text-text-primary font-mono text-lg outline-none focus:border-teal transition-colors"
          min={minWithdrawUsd}
          max={balanceUsd}
          step="0.01"
        />
      </div>
      <p className="text-xs text-text-tertiary mb-4">
        Available: ${balanceUsd.toFixed(2)} · Min: ${minWithdrawUsd.toFixed(2)}
      </p>
      {tooSmall && (
        <p className="text-xs text-coral mb-3">Minimum withdrawal is ${minWithdrawUsd.toFixed(2)}.</p>
      )}
      {tooLarge && (
        <p className="text-xs text-coral mb-3">Insufficient balance.</p>
      )}

      {/* Method picker */}
      <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
        Speed
      </label>
      <div className="grid grid-cols-1 gap-2 mb-4">
        <MethodOption
          selected={method === "standard"}
          onClick={() => onMethodChange("standard")}
          icon={<Clock size={14} />}
          label="Standard"
          eta="1-2 business days"
          fee="Free"
        />
        <MethodOption
          selected={method === "instant"}
          onClick={() => status?.instant_eligible && onMethodChange("instant")}
          disabled={!status?.instant_eligible}
          icon={<Zap size={14} />}
          label="Instant"
          eta="~30 minutes"
          fee={`${(instantBps / 100).toFixed(2)}% (min $${instantMinUsd.toFixed(2)})`}
          tooltip={!status?.instant_eligible ? "Link a debit card via Stripe to enable Instant Payouts" : undefined}
        />
      </div>

      {/* Fee breakdown */}
      <div className="rounded-lg bg-bg-primary border border-border-dim p-3 mb-5 text-xs space-y-1">
        <div className="flex justify-between text-text-tertiary">
          <span>Withdrawal</span>
          <span className="font-mono">${amountNum.toFixed(2)}</span>
        </div>
        <div className="flex justify-between text-text-tertiary">
          <span>Fee</span>
          <span className="font-mono">${fee.toFixed(2)}</span>
        </div>
        <div className="flex justify-between text-text-primary font-bold pt-1 border-t border-border-subtle">
          <span>You receive</span>
          <span className="font-mono text-teal">${net.toFixed(2)}</span>
        </div>
      </div>

      <div className="flex gap-3">
        <button
          onClick={onCancel}
          disabled={loading}
          className="flex-1 py-3 rounded-lg border-2 border-border-dim text-text-secondary text-sm font-bold hover:bg-bg-hover transition-all"
        >
          Cancel
        </button>
        <button
          onClick={onConfirm}
          disabled={loading || !valid}
          className="flex-1 py-3 rounded-lg bg-teal border border-border-dim text-white font-bold text-sm hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all flex items-center justify-center gap-2"
        >
          {loading && <Loader2 size={14} className="animate-spin" />}
          {loading ? "Processing..." : `Withdraw $${amountNum.toFixed(2)}`}
        </button>
      </div>
    </div>
  );
}

function MethodOption({
  selected,
  onClick,
  disabled,
  icon,
  label,
  eta,
  fee,
  tooltip,
}: {
  selected: boolean;
  onClick: () => void;
  disabled?: boolean;
  icon: React.ReactNode;
  label: string;
  eta: string;
  fee: string;
  tooltip?: string;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={tooltip}
      className={`flex items-center justify-between gap-3 px-3 py-3 rounded-lg border-2 transition-all text-left ${
        selected
          ? "bg-teal/10 border-teal text-teal"
          : disabled
          ? "bg-bg-primary border-border-dim text-text-tertiary cursor-not-allowed opacity-60"
          : "bg-bg-primary border-border-dim text-text-secondary hover:border-teal/30 hover:text-teal"
      }`}
    >
      <div className="flex items-center gap-3">
        {icon}
        <div>
          <div className="text-sm font-semibold">{label}</div>
          <div className="text-xs font-mono text-text-tertiary">{eta}</div>
        </div>
      </div>
      <div className="text-xs font-mono">{fee}</div>
    </button>
  );
}
