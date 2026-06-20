"use client";

import { Shield, TrendingUp, Clock, Info } from "lucide-react";
import { FLOOR_TIERS } from "@/app/earn/calc";

/**
 * BaseRewardsPanel — provider-facing explainer for the base-rewards earnings
 * floor on the /earn page.
 *
 * Model: payout = usage_earnings + floor (additive). The floor is what a
 * machine earns on top of real inference for staying online and attested; real
 * inference is the upside that grows as the network fills up. The floor table
 * mirrors coordinator/payments/baserewards/floor.go.
 *
 * Honesty constraints (see docs/base-rewards.md): the "covers your Netflix"
 * line applies to 64GB+ machines only; we never call it a "guarantee" (it is
 * eligibility-gated and capped by a fixed monthly pool).
 */

function netflixLabel(floorUSD: number): string {
  if (floorUSD >= 18) return "Netflix Standard";
  if (floorUSD > 0) return "Netflix w/ ads";
  return "Usage only";
}

function netflixColor(floorUSD: number): string {
  if (floorUSD >= 18) return "text-accent-green";
  if (floorUSD > 0) return "text-accent-amber";
  return "text-text-tertiary";
}

export function BaseRewardsPanel({ highlightGB }: { highlightGB?: number }) {
  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      <div className="flex items-center gap-2 mb-2">
        <Shield size={18} className="text-accent-brand" />
        <h3 className="text-sm font-semibold text-text-primary">Base rewards (earnings floor)</h3>
      </div>
      <p className="text-sm text-text-secondary mb-5">
        On top of what you earn from real inference, attested machines earn a monthly{" "}
        <span className="text-text-primary font-medium">base reward</span> for staying online — so a{" "}
        <span className="text-text-primary font-medium">64GB+ Mac</span> clears a full Netflix
        subscription even while the network is still quiet. Real usage is the upside on top, and it
        grows as demand fills up the network.
      </p>

      <div className="overflow-hidden rounded-lg border border-border-subtle">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-bg-tertiary text-text-tertiary">
              <th className="text-left font-medium px-4 py-2">Unified memory</th>
              <th className="text-right font-medium px-4 py-2">Base reward / mo</th>
              <th className="text-right font-medium px-4 py-2">Covers</th>
            </tr>
          </thead>
          <tbody>
            {FLOOR_TIERS.map((t) => {
              const active = highlightGB != null && highlightGB >= t.minGB;
              return (
                <tr
                  key={t.minGB}
                  className={`border-t border-border-subtle ${active ? "bg-accent-brand/5" : ""}`}
                >
                  <td className="px-4 py-2 text-text-secondary">{t.label}</td>
                  <td className="px-4 py-2 text-right font-mono text-text-primary">
                    {t.floorUSD > 0 ? `$${t.floorUSD}` : "—"}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <span className={netflixColor(t.floorUSD)}>{netflixLabel(t.floorUSD)}</span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="mt-4 space-y-2">
        <div className="flex items-start gap-2 text-xs text-text-tertiary">
          <Clock size={13} className="shrink-0 mt-0.5" />
          <span>Requires staying online ≥90% of the month (the base reward ramps with uptime).</span>
        </div>
        <div className="flex items-start gap-2 text-xs text-text-tertiary">
          <TrendingUp size={13} className="shrink-0 mt-0.5" />
          <span>Usage earnings are paid on top of the base reward — you keep 100% of both.</span>
        </div>
        <div className="flex items-start gap-2 text-xs text-text-tertiary">
          <Info size={13} className="shrink-0 mt-0.5" />
          <span>
            Base rewards go to attested, actively-serving machines up to a fixed monthly budget; not
            a guarantee. See the docs for eligibility.
          </span>
        </div>
      </div>
    </div>
  );
}
