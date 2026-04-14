"use client";

import { useEffect, useState, useCallback } from "react";
import { useToastStore } from "@/hooks/useToast";
import { useAuth } from "@/hooks/useAuth";
import { useSignAndSendTransaction, useWallets } from "@privy-io/react-auth/solana";
import {
  createAssociatedTokenAccountInstruction,
  getAssociatedTokenAddress,
  createTransferInstruction,
} from "@solana/spl-token";
import { Connection, PublicKey, Transaction } from "@solana/web3.js";
import { TopBar } from "@/components/TopBar";
import {
  fetchBalance,
  fetchUsage,
  fetchWalletInfo,
  submitDepositTx,
  redeemInviteCode,
  type BalanceResponse,
  type UsageEntry,
  type WalletInfo,
} from "@/lib/api";
import {
  Clock,
  X,
  Loader2,
  DollarSign,
  TrendingUp,
  Ticket,
  Check,
  CreditCard,
  Wallet,
  Copy,
} from "lucide-react";
import { UsageChart } from "@/components/UsageChart";

const USDC_MINT = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
const USDC_DECIMALS = 6;
const SOLANA_RPC = "https://api.mainnet-beta.solana.com";

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

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      onClick={() => {
        navigator.clipboard.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      }}
      className="p-1 rounded hover:bg-bg-hover text-text-tertiary hover:text-text-primary transition-colors"
      title="Copy"
    >
      {copied ? <Check size={12} className="text-teal" /> : <Copy size={12} />}
    </button>
  );
}

export default function BillingContent() {
  const addToast = useToastStore((s) => s.addToast);
  const { walletAddress } = useAuth();
  const { signAndSendTransaction } = useSignAndSendTransaction();
  const { wallets } = useWallets();
  const [balance, setBalance] = useState<BalanceResponse | null>(null);
  const [usage, setUsage] = useState<UsageEntry[]>([]);
  const [walletInfo, setWalletInfo] = useState<WalletInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [buyOpen, setBuyOpen] = useState(false);
  const [buyAmount, setBuyAmount] = useState("10");
  const [actionLoading, setActionLoading] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
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
      const [b, u, w] = await Promise.all([
        fetchBalance(),
        fetchUsage(),
        fetchWalletInfo().catch(() => null),
      ]);
      setBalance(b);
      setUsage(u);
      if (w) setWalletInfo(w);
    } catch (e) {
      addToast(`Failed to load billing data: ${(e as Error).message}`);
    }
    setLoading(false);
  }, [addToast]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  const handleBuyCredits = async () => {
    const embeddedWallet = wallets.find((w) => w.address === walletAddress);
    if (!embeddedWallet) {
      addToast("No wallet found. Sign in again.");
      return;
    }
    const coordAddr = walletInfo?.coordinator_address;
    if (!coordAddr) {
      addToast("Coordinator wallet address not available. Try refreshing.");
      return;
    }

    setActionLoading(true);
    try {
      const connection = new Connection(SOLANA_RPC);
      const fromPubkey = new PublicKey(embeddedWallet.address);
      const toPubkey = new PublicKey(coordAddr);
      const amountLamports = Math.round(parseFloat(buyAmount) * 10 ** USDC_DECIMALS);

      const sourceATA = await getAssociatedTokenAddress(USDC_MINT, fromPubkey);
      const destATA = await getAssociatedTokenAddress(USDC_MINT, toPubkey);

      const tx = new Transaction();

      // Create destination ATA if it doesn't exist
      const destAccount = await connection.getAccountInfo(destATA);
      if (!destAccount) {
        tx.add(
          createAssociatedTokenAccountInstruction(fromPubkey, destATA, toPubkey, USDC_MINT)
        );
      }

      tx.add(createTransferInstruction(sourceATA, destATA, fromPubkey, amountLamports));
      tx.feePayer = fromPubkey;
      tx.recentBlockhash = (await connection.getLatestBlockhash()).blockhash;

      const serialized = tx.serialize({ requireAllSignatures: false });

      const result = await signAndSendTransaction({
        transaction: serialized,
        wallet: embeddedWallet,
        options: { sponsor: true },
      });

      // Submit the on-chain tx signature to the coordinator for credit
      await submitDepositTx(result.signature);

      setBuyOpen(false);
      addToast(`$${buyAmount} credits added`, "success");
      loadData();
    } catch (e) {
      addToast(`${(e as Error).message}`);
    }
    setActionLoading(false);
  };

  const handleRedeem = async () => {
    const code = inviteCode.trim().toUpperCase();
    if (!code) return;
    setInviteLoading(true);
    setInviteSuccess("");
    try {
      const result = await redeemInviteCode(code);
      setInviteSuccess(`$${result.credited_usd} credited to your account`);
      setInviteCode("");
      loadData();
    } catch (e) {
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

  const displayWallet = walletInfo?.wallet_address || walletAddress;
  const truncatedWallet = displayWallet
    ? `${displayWallet.slice(0, 6)}...${displayWallet.slice(-4)}`
    : null;

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Billing" />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-4xl mx-auto px-3 sm:px-6 py-6 sm:py-8 space-y-8">
          {/* Balance Card */}
          <div className="relative overflow-hidden rounded-2xl border border-border-dim bg-bg-white p-6 sm:p-8 shadow-md">
            <div className="relative">
              <p className="text-xs font-mono text-text-tertiary uppercase tracking-widest mb-2">
                Available Credits
              </p>
              {loading ? (
                <div className="flex items-center gap-2 text-text-tertiary">
                  <Loader2 size={16} className="animate-spin" />
                  <span className="text-sm">Loading...</span>
                </div>
              ) : (
                <div className="flex items-baseline gap-1 mb-4">
                  <span className="text-4xl font-bold text-text-primary font-mono tracking-tight">
                    ${Number(balance?.balance_usd ?? 0).toFixed(2)}
                  </span>
                  <span className="text-sm text-text-tertiary font-mono">
                    USD
                  </span>
                </div>
              )}

              {/* Wallet info */}
              {truncatedWallet && (
                <div className="flex items-center gap-2 mb-4 text-xs text-text-tertiary font-mono">
                  <Wallet size={12} />
                  <span>{truncatedWallet}</span>
                  <CopyButton text={displayWallet!} />
                  {walletInfo?.wallet_usdc_usd && (
                    <span className="ml-2 text-teal font-semibold">
                      {walletInfo.wallet_usdc_usd} USDC
                    </span>
                  )}
                </div>
              )}

              <button
                onClick={() => setBuyOpen(true)}
                className="flex items-center gap-2 px-5 py-2.5 rounded-lg bg-coral border border-border-dim text-white text-sm font-bold
                           hover:opacity-90 transition-all"
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
                          {sortField === key && (sortAsc ? " \u2191" : " \u2193")}
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

          {/* Wallet info in modal */}
          {truncatedWallet && (
            <div className="rounded-lg bg-bg-primary border-2 border-border-dim p-3 mb-4">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2 text-xs text-text-tertiary">
                  <Wallet size={12} />
                  <span className="font-mono">{truncatedWallet}</span>
                  <CopyButton text={displayWallet!} />
                </div>
                {walletInfo?.wallet_usdc_usd && (
                  <span className="text-xs font-mono font-semibold text-teal">
                    {walletInfo.wallet_usdc_usd} USDC
                  </span>
                )}
              </div>
            </div>
          )}

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
              step="1"
            />
          </div>
          <div className="flex gap-2 mb-6">
            {[5, 10, 25, 50].map((amt) => (
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
            onClick={() => setConfirmOpen(true)}
            disabled={actionLoading || !buyAmount || parseFloat(buyAmount) <= 0}
            className="w-full py-3 rounded-lg bg-coral border border-border-dim text-white font-bold text-sm
                       hover:opacity-90
                       disabled:opacity-50
                       transition-all flex items-center justify-center gap-2"
          >
            Continue
          </button>
          <p className="mt-4 text-xs text-text-tertiary text-center">
            Paid via USDC on Solana. Transaction fees are sponsored.
          </p>
        </div>
      </Modal>

      {/* Confirmation Modal */}
      <Modal open={confirmOpen} onClose={() => !actionLoading && setConfirmOpen(false)}>
        <div className="px-6 pb-6">
          <h3 className="text-xl font-semibold text-ink mb-2">Confirm Purchase</h3>
          <p className="text-sm text-text-secondary mb-4">
            This will transfer <span className="font-bold text-text-primary">${buyAmount} USDC</span> from your wallet to buy inference credits.
          </p>

          {truncatedWallet && walletInfo?.wallet_usdc_usd && (
            <div className="rounded-lg bg-bg-primary border-2 border-border-dim p-3 mb-4 text-xs">
              <div className="flex justify-between text-text-tertiary">
                <span>Wallet balance</span>
                <span className="font-mono font-semibold text-teal">{walletInfo.wallet_usdc_usd} USDC</span>
              </div>
              <div className="flex justify-between text-text-tertiary mt-1">
                <span>After purchase</span>
                <span className="font-mono">{(parseFloat(walletInfo.wallet_usdc_usd) - parseFloat(buyAmount)).toFixed(2)} USDC</span>
              </div>
            </div>
          )}

          <div className="flex gap-3">
            <button
              onClick={() => setConfirmOpen(false)}
              disabled={actionLoading}
              className="flex-1 py-3 rounded-lg border-2 border-border-dim text-text-secondary text-sm font-bold hover:bg-bg-hover transition-all"
            >
              Cancel
            </button>
            <button
              onClick={async () => {
                await handleBuyCredits();
                setConfirmOpen(false);
              }}
              disabled={actionLoading}
              className="flex-1 py-3 rounded-lg bg-coral border border-border-dim text-white font-bold text-sm
                         hover:opacity-90
                         disabled:opacity-50 transition-all flex items-center justify-center gap-2"
            >
              {actionLoading && <Loader2 size={14} className="animate-spin" />}
              {actionLoading ? "Processing..." : `Confirm $${buyAmount}`}
            </button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
