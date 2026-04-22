"use client";

import { useEffect, useState, useCallback } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useToastStore } from "@/hooks/useToast";
import {
  fetchStripeStatus,
  startStripeOnboarding,
  withdrawStripe,
  fetchStripeWithdrawals,
  computeStripeFeeUsd,
  type StripeStatus,
  type StripeWithdrawal,
} from "@/lib/api";
import {
  Loader2,
  DollarSign,
  Briefcase,
  TrendingUp,
  LogIn,
  ArrowDownToLine,
  Check,
  AlertCircle,
  Building2,
  CreditCard,
  Clock,
  Zap,
  X,
} from "lucide-react";

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
}

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

export default function EarningsContent() {
  const { authenticated, login, getAccessToken } = useAuth();
  const addToast = useToastStore((s) => s.addToast);
  const [data, setData] = useState<EarningsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Stripe Payouts state
  const [stripeStatus, setStripeStatus] = useState<StripeStatus | null>(null);
  const [stripeWithdrawals, setStripeWithdrawals] = useState<StripeWithdrawal[]>([]);
  const [stripeOnboardLoading, setStripeOnboardLoading] = useState(false);
  const [withdrawOpen, setWithdrawOpen] = useState(false);
  const [withdrawAmount, setWithdrawAmount] = useState("10");
  const [withdrawMethod, setWithdrawMethod] = useState<"standard" | "instant">("standard");
  const [withdrawLoading, setWithdrawLoading] = useState(false);

  const getAuthHeaders = useCallback(async () => {
    const accessToken = await getAccessToken().catch(() => null);
    if (accessToken) {
      return { Authorization: `Bearer ${accessToken}` };
    }

    const apiKey = localStorage.getItem("darkbloom_api_key") || "";
    return apiKey ? { Authorization: `Bearer ${apiKey}` } : {};
  }, [getAccessToken]);

  const fetchEarnings = useCallback(async () => {
    setError(null);
    try {
      const coordinatorUrl =
        localStorage.getItem("darkbloom_coordinator_url") ||
        process.env.NEXT_PUBLIC_COORDINATOR_URL ||
        "https://api.darkbloom.dev";
      const headers = await getAuthHeaders();

      const res = await fetch(
        `${coordinatorUrl}/v1/provider/account-earnings?limit=100`,
        {
          headers,
        }
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setData(await res.json());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [getAuthHeaders]);

  const loadStripe = useCallback(async (refresh = false) => {
    try {
      const [s, wds] = await Promise.all([
        fetchStripeStatus(refresh),
        fetchStripeWithdrawals(20).catch(() => [] as StripeWithdrawal[]),
      ]);
      setStripeStatus(s);
      setStripeWithdrawals(wds);
    } catch (e) {
      console.warn("stripe status fetch failed:", (e as Error).message);
    }
  }, []);

  useEffect(() => {
    if (!authenticated) {
      setLoading(false);
      return;
    }
    fetchEarnings();
    const interval = setInterval(fetchEarnings, 30000);
    return () => clearInterval(interval);
  }, [authenticated, fetchEarnings]);

  // Load Stripe status; detect return from Stripe onboarding
  useEffect(() => {
    if (!authenticated) return;
    const params = typeof window !== "undefined" ? new URLSearchParams(window.location.search) : null;
    const justReturned = params?.get("stripe_return") === "1";
    loadStripe(justReturned);
    if (justReturned) {
      addToast("Stripe onboarding complete — verifying...", "success");
      const url = new URL(window.location.href);
      url.searchParams.delete("stripe_return");
      window.history.replaceState({}, "", url.toString());
    }
  }, [authenticated, loadStripe, addToast]);

  const handleStripeOnboard = async () => {
    setStripeOnboardLoading(true);
    try {
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
      await Promise.all([fetchEarnings(), loadStripe(false)]);
    } catch (e) {
      addToast(`${(e as Error).message}`);
    }
    setWithdrawLoading(false);
  };

  if (!authenticated) {
    return (
      <div className="max-w-4xl mx-auto p-6">
        <div className="text-center py-16">
          <LogIn size={32} className="mx-auto mb-3 text-text-tertiary opacity-50" />
          <p className="text-sm text-text-tertiary mb-4">
            Sign in to view your provider earnings.
          </p>
          <button
            onClick={login}
            className="px-4 py-2 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all"
          >
            Sign In
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
  const availableBalance = data?.available_balance_usd || "0.000000";
  const availableBalanceMicro = data?.available_balance_micro_usd || 0;
  const totalJobs = data?.count || 0;
  const recentCount = data?.recent_count ?? data?.earnings.length ?? 0;

  const ready = stripeStatus?.status === "ready";
  const restricted = stripeStatus?.status === "restricted";
  const rejected = stripeStatus?.status === "rejected";
  const pending = stripeStatus?.status === "pending";
  const minWithdrawUsd = (stripeStatus?.min_withdraw_micro_usd ?? 1_000_000) / 1_000_000;
  const availableUsd = availableBalanceMicro / 1_000_000;
  const canWithdraw = ready && availableUsd >= minWithdrawUsd;

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
      <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
        <div className="flex items-center gap-2 mb-1">
          <ArrowDownToLine size={16} className="text-teal" />
          <h3 className="text-sm font-semibold text-text-primary">Withdraw Earnings</h3>
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

        {/* Available balance display */}
        <div className="flex items-baseline gap-1 mb-4 mt-3">
          <span className="text-3xl font-bold text-text-primary font-mono tracking-tight">
            ${availableBalance}
          </span>
          <span className="text-sm text-text-tertiary font-mono">available</span>
        </div>

        {!stripeStatus?.has_account ? (
          <>
            <p className="text-sm text-text-secondary mb-4 leading-relaxed">
              Link a bank account or debit card via Stripe to withdraw your earnings.
              Stripe handles identity verification — onboarding takes about 2 minutes.
            </p>
            <button
              onClick={handleStripeOnboard}
              disabled={stripeOnboardLoading}
              className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 transition-all"
            >
              {stripeOnboardLoading ? <Loader2 size={14} className="animate-spin" /> : <Building2 size={14} />}
              {stripeOnboardLoading ? "Redirecting..." : "Link bank via Stripe"}
            </button>
          </>
        ) : ready ? (
          <>
            <div className="rounded-lg bg-bg-primary border border-border-dim p-3 mb-4 flex items-center justify-between">
              <div className="flex items-center gap-2 text-sm text-text-secondary">
                {stripeStatus.destination_type === "card" ? (
                  <CreditCard size={14} className="text-teal" />
                ) : (
                  <Building2 size={14} className="text-teal" />
                )}
                <span className="font-mono">
                  {stripeStatus.destination_type === "card" ? "Debit card" : "Bank"} ••{stripeStatus.destination_last4}
                </span>
                {stripeStatus.instant_eligible && (
                  <span className="text-[10px] font-mono uppercase text-gold bg-gold/10 border border-gold/30 rounded px-1.5 py-0.5">
                    Instant
                  </span>
                )}
              </div>
            </div>
            <button
              onClick={() => {
                setWithdrawAmount(availableUsd >= minWithdrawUsd ? availableUsd.toFixed(2) : "10");
                setWithdrawMethod(stripeStatus?.instant_eligible ? "instant" : "standard");
                setWithdrawOpen(true);
              }}
              disabled={!canWithdraw}
              className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-all"
            >
              <ArrowDownToLine size={14} />
              Withdraw
            </button>
            {!canWithdraw && availableUsd < minWithdrawUsd && (
              <p className="text-xs text-text-tertiary mt-2">
                Minimum withdrawal is ${minWithdrawUsd.toFixed(2)} — your available balance is ${availableUsd.toFixed(2)}.
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
                onClick={handleStripeOnboard}
                disabled={stripeOnboardLoading}
                className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-teal border-2 border-ink text-white text-sm font-bold hover:opacity-90 disabled:opacity-50 transition-all"
              >
                {stripeOnboardLoading ? <Loader2 size={14} className="animate-spin" /> : <Building2 size={14} />}
                {stripeOnboardLoading ? "Redirecting..." : restricted ? "Provide more info" : "Continue setup"}
              </button>
            )}
          </>
        )}

        {stripeWithdrawals.length > 0 && (
          <div className="mt-5 pt-5 border-t border-border-subtle">
            <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
              Recent withdrawals
            </p>
            <div className="space-y-2">
              {stripeWithdrawals.slice(0, 5).map((w) => (
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
      <Modal open={withdrawOpen} onClose={() => !withdrawLoading && setWithdrawOpen(false)}>
        <StripeWithdrawModal
          status={stripeStatus}
          balanceMicroUsd={availableBalanceMicro}
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
