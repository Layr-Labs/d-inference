"use client";

import { ChevronDown, Clock, Info, TrendingUp } from "lucide-react";
import type { EarningsMarketBaseRewards } from "@/lib/api";
import { fmtUSD, fmtUSDWhole } from "@/app/earn/calc";

export function BaseRewardsPanel({
  policy,
  state,
}: {
  policy: EarningsMarketBaseRewards | null;
  state: "loading" | "ready" | "unavailable";
}) {
  const tiers = policy
    ? [...policy.tiers].sort((a, b) => b.min_ram_gb - a.min_ram_gb)
    : [];
  const minimumTierGB = tiers.at(-1)?.min_ram_gb ?? 0;

  return (
    <details className="group rounded-xl bg-bg-secondary mb-6 open:pb-2">
      <summary className="flex items-center justify-between px-6 py-4 cursor-pointer list-none select-none">
        <span className="text-sm font-medium text-text-primary">
          Base reward policy (eligibility- and pool-capped)
        </span>
        <ChevronDown
          size={16}
          className="text-text-secondary transition-transform group-open:rotate-180"
        />
      </summary>

      <div className="px-6 pb-4">
        {state === "loading" && (
          <p className="text-sm text-text-secondary">Loading configured reward policy…</p>
        )}
        {state !== "loading" && (state === "unavailable" || !policy) && (
          <p className="text-sm text-text-secondary">Reward policy unavailable.</p>
        )}
        {state === "ready" && policy && (
          <>
            <p className="text-sm text-text-secondary mb-4">
              The table shows each machine&apos;s maximum monthly tier at full availability,
              before work offsets, attestation, health, uptime, and allocator checks. All
              eligible machines share one fixed{" "}
              {fmtUSD(policy.monthly_pool_micro_usd / 1_000_000)} monthly pool, so a tier
              amount is not guaranteed.
            </p>

            <div className="overflow-hidden rounded-lg border border-border-subtle">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-bg-tertiary text-text-secondary">
                    <th className="text-left font-medium px-4 py-2">Unified memory</th>
                    <th className="text-right font-medium px-4 py-2">Max / month</th>
                    <th className="text-right font-medium px-4 py-2">Max / year</th>
                  </tr>
                </thead>
                <tbody>
                  {tiers.map((tier) => {
                    const monthlyUSD = tier.monthly_micro_usd / 1_000_000;
                    return (
                      <tr key={tier.min_ram_gb} className="border-t border-border-subtle">
                        <td className="px-4 py-2 text-text-secondary">{tier.min_ram_gb}GB+</td>
                        <td className="px-4 py-2 text-right font-mono text-text-primary">
                          {fmtUSDWhole(monthlyUSD)}
                        </td>
                        <td className="px-4 py-2 text-right font-mono text-text-secondary">
                          {fmtUSDWhole(monthlyUSD * 12)}
                        </td>
                      </tr>
                    );
                  })}
                  <tr className="border-t border-border-subtle">
                    <td className="px-4 py-2 text-text-secondary">
                      Under {minimumTierGB}GB
                    </td>
                    <td className="px-4 py-2 text-right font-mono text-text-primary">—</td>
                    <td className="px-4 py-2 text-right font-mono text-text-secondary">—</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div className="mt-4 space-y-2">
              <div className="flex items-start gap-2 text-xs text-text-secondary">
                <Clock size={13} className="shrink-0 mt-0.5" />
                <span>
                  Eligibility requires at least{" "}
                  {Math.round(policy.min_uptime_fraction * 100)}% uptime in each settlement
                  period; full tier credit requires full availability.
                </span>
              </div>
              <div className="flex items-start gap-2 text-xs text-text-secondary">
                <TrendingUp size={13} className="shrink-0 mt-0.5" />
                <span>
                  {policy.reduction_k === 0
                    ? "Settled inference work is paid on top of any allocated reward."
                    : `Each five-minute reward draw is reduced by ${policy.reduction_k.toFixed(2)}× inference earnings settled in that same period before allocation.`}
                </span>
              </div>
              <div className="flex items-start gap-2 text-xs text-text-secondary">
                <Info size={13} className="shrink-0 mt-0.5" />
                <span>
                  {policy.enabled
                    ? `The program is enabled; each amount remains subject to eligibility and the fleet-wide pool cap${
                        policy.account_cap_fraction > 0
                          ? `, plus a ${(policy.account_cap_fraction * 100).toFixed(1)}% per-account pool cap`
                          : ""
                      }.`
                    : "The program is currently disabled; the policy table does not create a payout."}
                </span>
              </div>
            </div>
          </>
        )}
      </div>
    </details>
  );
}
