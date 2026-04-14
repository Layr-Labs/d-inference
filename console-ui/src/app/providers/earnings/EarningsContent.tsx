"use client";

import { useEffect, useState, useCallback } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useSignAndSendTransaction, useWallets } from "@privy-io/react-auth/solana";
import {
  createAssociatedTokenAccountInstruction,
  getAssociatedTokenAddress,
  createTransferInstruction,
} from "@solana/spl-token";
import { Connection, PublicKey, Transaction } from "@solana/web3.js";
import {
  Loader2,
  DollarSign,
  Briefcase,
  TrendingUp,
  LogIn,
  ArrowDownToLine,
  ArrowUpRight,
  Check,
  AlertCircle,
  Wallet,
} from "lucide-react";

const USDC_MINT = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
const USDC_DECIMALS = 6;
const SOLANA_RPC = "https://api.mainnet-beta.solana.com";

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
}

export default function EarningsContent() {
  const { authenticated, login, walletAddress } = useAuth();
  const { signAndSendTransaction } = useSignAndSendTransaction();
  const { wallets } = useWallets();
  const [data, setData] = useState<EarningsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Claim state (coordinator → Privy wallet)
  const [claiming, setClaiming] = useState(false);
  const [claimResult, setClaimResult] = useState<{ ok: boolean; msg: string } | null>(null);

  // Withdraw state (Privy wallet → external)
  const [withdrawAddr, setWithdrawAddr] = useState("");
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawing, setWithdrawing] = useState(false);
  const [withdrawResult, setWithdrawResult] = useState<{ ok: boolean; msg: string } | null>(null);

  const fetchEarnings = useCallback(async () => {
    try {
      const apiKey = localStorage.getItem("darkbloom_api_key") || "";
      const coordinatorUrl =
        localStorage.getItem("darkbloom_coordinator_url") ||
        process.env.NEXT_PUBLIC_COORDINATOR_URL ||
        "https://api.darkbloom.dev";

      const res = await fetch(
        `${coordinatorUrl}/v1/provider/account-earnings?limit=100`,
        {
          headers: {
            ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
          },
        }
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setData(await res.json());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
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

  // Step 1: Claim all earnings → sends USDC from coordinator hot wallet to Privy wallet
  const handleClaim = useCallback(async () => {
    if (!walletAddress) return;
    const totalMicro = data?.total_micro_usd || 0;
    if (totalMicro < 1_000_000) return;

    setClaiming(true);
    setClaimResult(null);
    try {
      const apiKey = localStorage.getItem("darkbloom_api_key") || "";
      const coordinatorUrl =
        localStorage.getItem("darkbloom_coordinator_url") ||
        process.env.NEXT_PUBLIC_COORDINATOR_URL ||
        "https://api.darkbloom.dev";

      const amountUsd = (totalMicro / 1_000_000).toFixed(2);

      const res = await fetch(`${coordinatorUrl}/v1/billing/withdraw/solana`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
        },
        body: JSON.stringify({
          amount_usd: amountUsd,
          wallet_address: walletAddress,
        }),
      });

      if (!res.ok) {
        const errData = await res.json().catch(() => ({}));
        const msg = errData?.error?.message || errData?.error || `Claim failed (${res.status})`;
        throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
      }

      const result = await res.json();
      setClaimResult({
        ok: true,
        msg: `$${amountUsd} USDC claimed to your wallet. Tx: ${(result.tx_signature || "").slice(0, 16)}...`,
      });
      fetchEarnings();
    } catch (e) {
      setClaimResult({ ok: false, msg: (e as Error).message });
    } finally {
      setClaiming(false);
    }
  }, [data, walletAddress, fetchEarnings]);

  // Step 2: Withdraw USDC from Privy wallet → external address (gas-sponsored)
  const handleWithdraw = useCallback(async () => {
    if (!withdrawAddr || !withdrawAmount) return;
    const amount = parseFloat(withdrawAmount);
    if (isNaN(amount) || amount <= 0) return;

    const embeddedWallet = wallets.find((w) => w.address === walletAddress);
    if (!embeddedWallet) {
      setWithdrawResult({ ok: false, msg: "No wallet found. Sign in again." });
      return;
    }

    setWithdrawing(true);
    setWithdrawResult(null);
    try {
      const connection = new Connection(SOLANA_RPC);
      const fromPubkey = new PublicKey(embeddedWallet.address);
      const toPubkey = new PublicKey(withdrawAddr);
      const amountLamports = Math.round(amount * 10 ** USDC_DECIMALS);

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

      setWithdrawResult({
        ok: true,
        msg: `$${withdrawAmount} USDC sent. Tx: ${(result.signature || "").slice(0, 16)}...`,
      });
      setWithdrawAmount("");
      setWithdrawAddr("");
    } catch (e) {
      setWithdrawResult({ ok: false, msg: (e as Error).message });
    } finally {
      setWithdrawing(false);
    }
  }, [withdrawAddr, withdrawAmount, wallets, signAndSendTransaction]);

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
  const totalMicro = data?.total_micro_usd || 0;
  const jobCount = data?.count || 0;
  const canClaim = totalMicro >= 1_000_000;

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
            {jobCount}
          </p>
        </div>
        <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
          <div className="flex items-center gap-2 mb-2">
            <TrendingUp size={16} className="text-accent-brand" />
            <p className="text-xs text-text-tertiary">Avg per Job</p>
          </div>
          <p className="text-2xl font-bold text-text-primary">
            ${jobCount > 0 ? (parseFloat(totalEarned) / jobCount).toFixed(6) : "0.00"}
          </p>
        </div>
      </div>

      {/* Step 1: Claim Fees */}
      <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
        <div className="flex items-center gap-2 mb-1">
          <ArrowDownToLine size={16} className="text-accent-green" />
          <h3 className="text-sm font-semibold text-text-primary">Step 1 — Claim Fees</h3>
        </div>
        <p className="text-xs text-text-tertiary mb-4">
          Transfer your earned USDC from the Darkbloom coordinator to your Privy wallet.
        </p>

        {!walletAddress ? (
          <p className="text-sm text-text-tertiary">
            Link a Solana wallet to your account to claim earnings.
          </p>
        ) : (
          <>
            <div className="flex items-center gap-3 mb-4 px-3 py-2.5 rounded-lg bg-bg-primary border border-border-dim">
              <Wallet size={14} className="text-text-tertiary" />
              <div className="flex-1 min-w-0">
                <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wide">Your Privy Wallet</p>
                <p className="text-sm font-mono text-text-primary truncate">{walletAddress}</p>
              </div>
            </div>

            <div className="flex items-center gap-3">
              <div className="flex-1">
                <p className="text-sm font-mono text-text-primary">
                  ${totalEarned} <span className="text-text-tertiary">available</span>
                </p>
              </div>
              <button
                onClick={handleClaim}
                disabled={claiming || !canClaim}
                className="px-5 py-2.5 rounded-lg bg-coral text-white text-sm font-semibold hover:opacity-90 disabled:opacity-40 transition-all flex items-center gap-2"
              >
                {claiming ? <Loader2 size={14} className="animate-spin" /> : <ArrowDownToLine size={14} />}
                Claim All
              </button>
            </div>

            {!canClaim && totalMicro > 0 && (
              <p className="text-xs text-text-tertiary mt-2">
                Minimum claim is $1.00
              </p>
            )}

            {claimResult && (
              <div className={`flex items-center gap-2 mt-3 text-xs font-medium ${
                claimResult.ok ? "text-accent-green" : "text-accent-red"
              }`}>
                {claimResult.ok ? <Check size={14} /> : <AlertCircle size={14} />}
                {claimResult.msg}
              </div>
            )}
          </>
        )}
      </div>

      {/* Step 2: Withdraw to Exchange */}
      <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
        <div className="flex items-center gap-2 mb-1">
          <ArrowUpRight size={16} className="text-accent-brand" />
          <h3 className="text-sm font-semibold text-text-primary">Step 2 — Withdraw to Exchange</h3>
        </div>
        <p className="text-xs text-text-tertiary mb-4">
          Send USDC from your Privy wallet to an external wallet or exchange. Gas fees are sponsored.
        </p>

        <div className="space-y-3">
          <input
            type="text"
            value={withdrawAddr}
            onChange={(e) => { setWithdrawResult(null); setWithdrawAddr(e.target.value); }}
            placeholder="Destination Solana address"
            className="w-full bg-bg-primary border border-border-dim rounded-lg px-3 py-2.5 text-sm font-mono text-text-primary outline-none focus:border-accent-brand/50 transition-colors placeholder:text-text-tertiary/50"
          />
          <div className="flex gap-2">
            <div className="relative flex-1">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-text-tertiary text-sm">$</span>
              <input
                type="number"
                step="0.01"
                min="0.01"
                value={withdrawAmount}
                onChange={(e) => { setWithdrawResult(null); setWithdrawAmount(e.target.value); }}
                placeholder="0.00"
                className="w-full bg-bg-primary border border-border-dim rounded-lg pl-7 pr-3 py-2.5 text-sm font-mono text-text-primary outline-none focus:border-accent-brand/50 transition-colors"
              />
            </div>
            <button
              onClick={handleWithdraw}
              disabled={withdrawing || !withdrawAddr || !withdrawAmount}
              className="px-5 py-2.5 rounded-lg bg-coral text-white text-sm font-semibold hover:opacity-90 disabled:opacity-40 transition-all flex items-center gap-2"
            >
              {withdrawing ? <Loader2 size={14} className="animate-spin" /> : <ArrowUpRight size={14} />}
              Send
            </button>
          </div>
        </div>

        {withdrawResult && (
          <div className={`flex items-center gap-2 mt-3 text-xs font-medium ${
            withdrawResult.ok ? "text-accent-green" : "text-accent-red"
          }`}>
            {withdrawResult.ok ? <Check size={14} /> : <AlertCircle size={14} />}
            {withdrawResult.msg}
          </div>
        )}
      </div>

      {/* Earnings history */}
      <div>
        <h3 className="text-sm font-semibold text-text-primary mb-3">Recent Activity</h3>
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
    </div>
  );
}
