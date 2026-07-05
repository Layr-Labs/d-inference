"use client";

import { Clock, Zap, Loader2 } from "lucide-react";
import { computeStripeFeeUsd, type StripeStatus } from "@/lib/api";
import { MethodOption } from "./MethodOption";

// The Stripe withdraw modal body (amount input, speed picker, fee preview,
// confirm). Shared by billing + earnings (previously byte-identical — F3).
export function StripeWithdrawModal({
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
