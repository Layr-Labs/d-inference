"use client";

import { ChevronDown, Clock, TrendingUp, Info } from "lucide-react";
import { FLOOR_TIERS } from "@/app/earn/calc";

/**
 * BaseRewardsPanel — collapsed explainer for the base-rewards earnings floor
 * on the /earn page. A static reference table (memory tier → monthly and
 * annualized floor), matching the "How we estimate this" accordion style.
 *
 * Model: payout = usage_earnings + floor (additive). The floor table mirrors
 * coordinator/payments/baserewards/floor.go.
 *
 * Honesty constraints (see docs/base-rewards.md): we never call it a
 * "guarantee" (it is eligibility-gated and capped by a fixed monthly pool).
 */
export function BaseRewardsPanel() {
  return (
    <details className="group rounded-xl bg-bg-secondary mb-6 open:pb-2">
      <summary className="flex items-center justify-between px-6 py-4 cursor-pointer list-none select-none">
        <span className="text-sm font-medium text-text-primary">Base rewards (earnings floor)</span>
        <ChevronDown
          size={16}
          className="text-text-secondary transition-transform group-open:rotate-180"
        />
      </summary>

      <div className="px-6 pb-4">
        <p className="text-sm text-text-secondary mb-4">
          On top of what you earn from real inference, attested machines accrue a monthly{" "}
          <span className="text-text-primary font-medium">base reward</span> for staying online.
          It is paid in 5-minute prorated increments, while real usage remains the upside on top.
        </p>

        <div className="overflow-hidden rounded-lg border border-border-subtle">
          <table className="w-full text-sm">
            <thead>
              <tr className="bg-bg-tertiary text-text-secondary">
                <th className="text-left font-medium px-4 py-2">Unified memory</th>
                <th className="text-right font-medium px-4 py-2">Per month</th>
                <th className="text-right font-medium px-4 py-2">Per year</th>
              </tr>
            </thead>
            <tbody>
              {FLOOR_TIERS.map((t) => (
                <tr key={t.minGB} className="border-t border-border-subtle">
                  <td className="px-4 py-2 text-text-secondary">{t.label}</td>
                  <td className="px-4 py-2 text-right font-mono text-text-primary">
                    {t.floorUSD > 0 ? `$${t.floorUSD}` : "—"}
                  </td>
                  <td className="px-4 py-2 text-right font-mono text-text-secondary">
                    {t.floorUSD > 0 ? `$${t.floorUSD * 12}` : "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-4 space-y-2">
          <div className="flex items-start gap-2 text-xs text-text-secondary">
            <Clock size={13} className="shrink-0 mt-0.5" />
            <span>Rewards settle every 5 minutes and require staying online ≥90% of that period.</span>
          </div>
          <div className="flex items-start gap-2 text-xs text-text-secondary">
            <TrendingUp size={13} className="shrink-0 mt-0.5" />
            <span>Usage earnings are paid on top of the base reward — you keep 100% of both.</span>
          </div>
          <div className="flex items-start gap-2 text-xs text-text-secondary">
            <Info size={13} className="shrink-0 mt-0.5" />
            <span>
              Base rewards go to attested, online, healthy machines up to a fixed monthly budget,
              prorated per settlement period; not a guarantee. See the docs for eligibility.
            </span>
          </div>
        </div>
      </div>
    </details>
  );
}
