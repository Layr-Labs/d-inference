"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Copy, Check } from "lucide-react";
import type { ReferralStats } from "@/lib/api/referrals";
import { referralButtonClass, referralInputClass } from "./ReferralRegistration";

export function ReferralEarnings({ stats }: { stats: ReferralStats }) {
  const [origin, setOrigin] = useState("");
  const [copied, setCopied] = useState(false);
  const [copyError, setCopyError] = useState(false);
  useEffect(() => { setOrigin(window.location.origin); }, []);
  const link = origin ? `${origin}/referrals?ref=${encodeURIComponent(stats.code)}` : "";

  async function copy() {
    setCopyError(false); setCopied(false);
    try { await navigator.clipboard.writeText(link); setCopied(true); }
    catch { setCopyError(true); }
  }

  return (
    <>
      <section className="border-b border-border-dim py-7">
        <h2 className="text-lg font-medium text-text-primary">Your referral link</h2>
        <p className="mt-2 text-sm text-text-secondary">Share this link with developers, teams, and anyone who needs private inference.</p>
        <div className="mt-5 flex flex-col gap-3 sm:flex-row">
          <input readOnly aria-label="Your referral link" value={link} onFocus={(event) => event.target.select()} className={referralInputClass} />
          <button onClick={() => void copy()} disabled={!link} className={`${referralButtonClass} gap-2`}>{copied ? <Check size={15} /> : <Copy size={15} />}{copied ? "Copied" : "Copy link"}</button>
        </div>
        <p className="mt-2 text-xs text-text-tertiary">Your code: <span className="font-mono text-text-primary">{stats.code}</span></p>
        {copyError && <p role="alert" className="mt-3 text-sm text-text-secondary">Couldn’t copy automatically. Select and copy the link above.</p>}
        {copied && <span role="status" className="sr-only">Referral link copied</span>}
      </section>
      <section className="border-b border-border-dim py-7" aria-label="Referral earnings">
        <h2 className="text-lg font-medium text-text-primary">Your impact</h2>
        <dl className="mt-5 grid grid-cols-1 gap-6 sm:grid-cols-3">
          <div><dt className="text-xs text-text-secondary">Consumers referred</dt><dd className="mt-2 text-2xl tabular-nums">{stats.total_referred.toLocaleString()}</dd></div>
          <div><dt className="text-xs text-text-secondary">Referred token spend</dt><dd className="mt-2 break-all text-xl tabular-nums">${stats.total_referred_spend_usd}</dd></div>
          <div><dt className="text-xs text-text-secondary">Lifetime referral rewards</dt><dd className="mt-2 break-all text-xl tabular-nums">${stats.total_rewards_usd}</dd></div>
        </dl>
        <p className="mt-5 text-xs leading-relaxed text-text-tertiary">Totals include billed token usage after the referral was applied. Rewards become withdrawable earnings; your account balance may also include other earnings.</p>
        <Link href="/billing" className="mt-4 inline-flex min-h-10 items-center text-sm font-medium text-accent-brand hover:underline">Manage withdrawals →</Link>
      </section>
    </>
  );
}
