"use client";

import { TopBar } from "@/components/TopBar";
import type { ReactNode } from "react";

export function ReferralPageLayout({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-full flex-col">
      <TopBar title="Referrals" />
      <div className="mx-auto w-full max-w-3xl px-4 py-7 pb-20 sm:px-8 sm:py-10">
        <header className="border-b border-border-dim pb-7">
          <p className="mb-3 text-xs font-medium uppercase tracking-widest text-accent-brand">Darkbloom referrals</p>
          <h1 className="font-logo text-4xl font-normal tracking-tight text-ink">Bring people to private AI.</h1>
          <p className="mt-4 max-w-xl text-sm leading-relaxed text-text-secondary">Earn 5% of their token spend when consumers you refer use Darkbloom. Rewards are funded by Darkbloom, at no extra cost to the consumer.</p>
          <p className="mt-3 text-xs leading-relaxed text-text-tertiary">For every $100 of billed token usage, you earn $5 in withdrawable rewards. Deposits and unused credits do not earn rewards.</p>
        </header>
        {children}
      </div>
    </div>
  );
}
