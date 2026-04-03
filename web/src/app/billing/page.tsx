"use client";

import { useEffect, useState, useCallback } from "react";
import { useToastStore } from "@/hooks/useToast";
import { TopBar } from "@/components/TopBar";
import {
  fetchBalance,
  fetchUsage,
  deposit,
  withdraw,
  type BalanceResponse,
  type UsageEntry,
} from "@/lib/api";
import {
  ArrowUpRight,
  ArrowDownLeft,
  Clock,
  X,
  Loader2,
  DollarSign,
  TrendingUp,
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
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="bg-bg-secondary border border-border-subtle rounded-xl w-full max-w-md mx-4 shadow-2xl">
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

export default function BillingPage() {
  const addToast = useToastStore((s) => s.addToast);
  const [balance, setBalance] = useState<BalanceResponse | null>(null);
  const [usage, setUsage] = useState<UsageEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [depositOpen, setDepositOpen] = useState(false);
  const [withdrawOpen, setWithdrawOpen] = useState(false);
  const [depositAmount, setDepositAmount] = useState("10");
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [walletAddr, setWalletAddr] = useState("");
  const [actionLoading, setActionLoading] = useState(false);
  const [sortField, setSortField] = useState<"timestamp" | "cost_micro_usd">(
    "timestamp"
  );
  const [sortAsc, setSortAsc] = useState(false);

  const loadData = useCallback(async () => {
    setLoading(true);
    try {
      const [b, u] = await Promise.all([fetchBalance(), fetchUsage()]);
      setBalance(b);
      setUsage(u);
    } catch (e) {
      addToast(`Failed to load billing data: ${(e as Error).message}`);
    }
    setLoading(false);
  }, [addToast]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  const handleDeposit = async () => {
    setActionLoading(true);
    try {
      await deposit(parseFloat(depositAmount));
      setDepositOpen(false);
      addToast("Deposit successful", "success");
      loadData();
    } catch (e) {
      addToast(`Deposit failed: ${(e as Error).message}`);
    }
    setActionLoading(false);
  };

  const handleWithdraw = async () => {
    setActionLoading(true);
    try {
      await withdraw(parseFloat(withdrawAmount), walletAddr);
      setWithdrawOpen(false);
      addToast("Withdrawal submitted", "success");
      loadData();
    } catch (e) {
      addToast(`Withdrawal failed: ${(e as Error).message}`);
    }
    setActionLoading(false);
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
        <div className="max-w-4xl mx-auto px-6 py-8 space-y-8">
          {/* Balance Card */}
          <div className="relative overflow-hidden rounded-2xl border border-border-subtle bg-bg-secondary p-8">
            {/* Decorative gradient */}
            <div className="absolute top-0 right-0 w-64 h-64 bg-accent-brand/5 rounded-full blur-3xl -translate-y-1/2 translate-x-1/2" />

            <div className="relative">
              <p className="text-xs font-mono text-text-tertiary uppercase tracking-widest mb-2">
                Available Balance
              </p>
              {loading ? (
                <div className="flex items-center gap-2 text-text-tertiary">
                  <Loader2 size={16} className="animate-spin" />
                  <span className="text-sm">Loading...</span>
                </div>
              ) : (
                <div className="flex items-baseline gap-1 mb-6">
                  <span className="text-4xl font-bold text-text-primary font-mono tracking-tight">
                    ${Number(balance?.balance_usd ?? 0).toFixed(2)}
                  </span>
                  <span className="text-sm text-text-tertiary font-mono">
                    USD
                  </span>
                </div>
              )}

              <div className="flex gap-3">
                <button
                  onClick={() => setDepositOpen(true)}
                  className="flex items-center gap-2 px-4 py-2.5 rounded-lg bg-accent-green/15 border border-accent-green/25 text-accent-green text-sm font-mono hover:bg-accent-green/25 transition-colors"
                >
                  <ArrowDownLeft size={14} />
                  Deposit
                </button>
                <button
                  onClick={() => setWithdrawOpen(true)}
                  className="flex items-center gap-2 px-4 py-2.5 rounded-lg bg-bg-tertiary border border-border-subtle text-text-secondary text-sm font-mono hover:bg-bg-hover transition-colors"
                >
                  <ArrowUpRight size={14} />
                  Withdraw
                </button>
              </div>
            </div>
          </div>

          {/* Stats row */}
          <div className="grid grid-cols-3 gap-4">
            {[
              {
                icon: DollarSign,
                label: "Total Spent",
                value: `$${(totalSpent / 1_000_000).toFixed(4)}`,
                color: "text-accent-brand",
              },
              {
                icon: TrendingUp,
                label: "Total Tokens",
                value: totalTokens.toLocaleString(),
                color: "text-accent-green",
              },
              {
                icon: Clock,
                label: "Requests",
                value: usage.length.toString(),
                color: "text-accent-amber",
              },
            ].map(({ icon: Icon, label, value, color }) => (
              <div
                key={label}
                className="rounded-xl bg-bg-secondary p-4 shadow-sm"
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
          <div className="rounded-xl bg-bg-secondary overflow-hidden shadow-sm">
            <div className="px-5 py-4 border-b border-border-subtle flex items-center gap-2">
              <Clock size={14} className="text-text-tertiary" />
              <h3 className="text-sm font-medium text-text-primary">
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
                          className={`px-5 py-3 text-left text-xs font-mono text-text-tertiary uppercase tracking-wider ${
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
                        <td className="px-5 py-3 font-mono text-xs text-text-secondary">
                          {new Date(entry.timestamp).toLocaleString()}
                        </td>
                        <td className="px-5 py-3">
                          <span className="font-mono text-xs text-accent-brand">
                            {entry.model.split("/").pop()}
                          </span>
                        </td>
                        <td className="px-5 py-3 font-mono text-xs text-text-secondary">
                          {entry.prompt_tokens + entry.completion_tokens}
                          <span className="text-text-tertiary ml-1">
                            ({entry.prompt_tokens}p / {entry.completion_tokens}c)
                          </span>
                        </td>
                        <td className="px-5 py-3 font-mono text-xs text-accent-green">
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

      {/* Deposit Modal */}
      <Modal open={depositOpen} onClose={() => setDepositOpen(false)}>
        <div className="px-6 pb-6">
          <h3 className="text-lg font-semibold text-text-primary mb-4">
            Deposit Funds
          </h3>
          <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
            Amount (USD)
          </label>
          <div className="flex items-center gap-2 mb-4">
            <span className="text-text-tertiary text-lg">$</span>
            <input
              type="number"
              value={depositAmount}
              onChange={(e) => setDepositAmount(e.target.value)}
              className="flex-1 bg-bg-tertiary border border-border-subtle rounded-lg px-4 py-3 text-text-primary font-mono text-lg outline-none focus:border-accent-green/50 transition-colors"
              min="1"
              step="1"
            />
          </div>
          <div className="flex gap-2 mb-4">
            {[5, 10, 25, 50].map((amt) => (
              <button
                key={amt}
                onClick={() => setDepositAmount(String(amt))}
                className="flex-1 py-2 rounded-lg bg-bg-tertiary border border-border-subtle text-text-secondary text-sm font-mono hover:border-accent-green/30 hover:text-accent-green transition-colors"
              >
                ${amt}
              </button>
            ))}
          </div>
          <button
            onClick={handleDeposit}
            disabled={actionLoading || !depositAmount}
            className="w-full py-3 rounded-lg bg-accent-green text-white font-medium text-sm hover:bg-accent-green/90 disabled:opacity-50 transition-colors flex items-center justify-center gap-2"
          >
            {actionLoading && <Loader2 size={14} className="animate-spin" />}
            Confirm Deposit
          </button>
        </div>
      </Modal>

      {/* Withdraw Modal */}
      <Modal open={withdrawOpen} onClose={() => setWithdrawOpen(false)}>
        <div className="px-6 pb-6">
          <h3 className="text-lg font-semibold text-text-primary mb-4">
            Withdraw Funds
          </h3>
          <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
            Amount (USD)
          </label>
          <input
            type="number"
            value={withdrawAmount}
            onChange={(e) => setWithdrawAmount(e.target.value)}
            placeholder="0.00"
            className="w-full bg-bg-tertiary border border-border-subtle rounded-lg px-4 py-3 text-text-primary font-mono mb-4 outline-none focus:border-accent-brand/50 transition-colors"
          />
          <label className="block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-2">
            Wallet Address
          </label>
          <input
            type="text"
            value={walletAddr}
            onChange={(e) => setWalletAddr(e.target.value)}
            placeholder="0x..."
            className="w-full bg-bg-tertiary border border-border-subtle rounded-lg px-4 py-3 text-text-primary font-mono text-sm mb-4 outline-none focus:border-accent-brand/50 transition-colors"
          />
          <button
            onClick={handleWithdraw}
            disabled={actionLoading || !withdrawAmount || !walletAddr}
            className="w-full py-3 rounded-lg bg-accent-brand text-white font-medium text-sm hover:bg-accent-brand/90 disabled:opacity-50 transition-colors flex items-center justify-center gap-2"
          >
            {actionLoading && <Loader2 size={14} className="animate-spin" />}
            Confirm Withdrawal
          </button>
        </div>
      </Modal>
    </div>
  );
}
