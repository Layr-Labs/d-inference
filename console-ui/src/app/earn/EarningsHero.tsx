"use client";

import { Shield, TrendingUp, Info } from "lucide-react";
import { fmtUSDWhole } from "./calc";
import { SmallModelsInterest } from "./SmallModelsInterest";
import type { EarningsCalculator } from "./useEarningsCalculator";

/**
 * Results-first hero: a floor→estimate range instead of a single speculative
 * number. The floor is the base reward (the only figure the network commits
 * to); the top of the range is the full-utilization estimate for the best
 * model that fits.
 */
export function EarningsHero({
  calc,
  authenticated,
  ready,
  login,
}: {
  calc: EarningsCalculator;
  authenticated: boolean;
  ready: boolean;
  login: () => void;
}) {
  const { result, bestModel, monthlyFloor, monthlyEstimate, effectiveRAM, catalogModels } = calc;

  const loading = catalogModels.length === 0;
  const showRange = result !== null && monthlyEstimate > monthlyFloor;
  const annualFloor = monthlyFloor * 12;
  const annualEstimate = monthlyEstimate * 12;

  return (
    <div className="rounded-xl bg-bg-secondary p-6 sm:p-8 mb-6 text-center">
      <p className="text-xs uppercase tracking-wider text-text-secondary mb-2">
        Estimated annual earnings
      </p>

      {loading ? (
        <p className="text-4xl sm:text-5xl font-bold font-mono text-text-primary py-2">…</p>
      ) : (
        <>
          <p className="text-4xl sm:text-5xl font-bold font-mono text-text-primary py-1">
            {showRange ? (
              <>
                {fmtUSDWhole(annualFloor)}
                <span className="text-text-secondary font-normal mx-1">–</span>
                {fmtUSDWhole(annualEstimate)}
              </>
            ) : (
              fmtUSDWhole(annualEstimate)
            )}
            <span className="text-lg font-normal text-text-secondary"> /yr</span>
          </p>
          <p className="text-sm text-text-secondary mt-1">
            {showRange
              ? `${fmtUSDWhole(monthlyFloor)} – ${fmtUSDWhole(monthlyEstimate)} per month`
              : `${fmtUSDWhole(monthlyEstimate)} per month`}
          </p>
        </>
      )}

      {!loading && (monthlyFloor > 0 || showRange) && (
        <div className="mt-4 flex flex-col sm:flex-row items-stretch sm:items-center justify-center gap-2 sm:gap-3">
          {monthlyFloor > 0 && (
            <div className="flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg bg-accent-brand/10 text-sm text-text-primary">
              <Shield size={14} className="text-accent-brand shrink-0" />
              <span>
                <span className="font-mono font-medium">{fmtUSDWhole(monthlyFloor)}/mo</span> base
                reward for staying online
              </span>
            </div>
          )}
          {showRange && bestModel && (
            <div className="flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue/10 text-sm text-text-primary">
              <TrendingUp size={14} className="text-blue shrink-0" />
              <span>
                up to <span className="font-mono font-medium">{fmtUSDWhole(monthlyEstimate)}/mo</span>{" "}
                serving {bestModel.name} at healthy demand
              </span>
            </div>
          )}
        </div>
      )}

      {!loading && !result && (
        <>
          <p className="mt-4 text-sm text-text-secondary">
            {monthlyFloor > 0
              ? `No catalog model fits in ${effectiveRAM} GB yet — you'd still earn the ${fmtUSDWhole(monthlyFloor)}/mo base reward.`
              : `No catalog model fits in ${effectiveRAM} GB yet.`}
          </p>
          <SmallModelsInterest
            calc={calc}
            authenticated={authenticated}
            ready={ready}
            login={login}
          />
        </>
      )}

      {!loading && (
        <div className="mt-4 flex items-start gap-2 text-left rounded-lg bg-bg-tertiary px-3 py-2.5">
          <Info size={14} className="text-text-secondary shrink-0 mt-0.5" aria-hidden />
          <p className="text-xs text-text-secondary">
            This is a projection, not a promise. Usage earnings assume healthy, sustained
            network demand — live demand fluctuates and can run below this. The base reward
            requires an attested, healthy machine that stays online ≥90% of each settlement
            period, and is paid from a fixed monthly pool — an earnings floor while eligible,
            not a guarantee.
          </p>
        </div>
      )}
    </div>
  );
}
