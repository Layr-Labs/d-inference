"use client";

import { Info, Shield, TrendingUp } from "lucide-react";
import { fmtUSD } from "./calc";
import { SmallModelsInterest } from "./SmallModelsInterest";
import type { EarningsCalculator } from "./useEarningsCalculator";

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
  const {
    result,
    bestModel,
    hasFittingModel,
    effectiveRAM,
    market,
    marketState,
  } = calc;
  const loading = marketState === "loading";

  let unavailableDetail = "";
  if (marketState === "unavailable") {
    unavailableDetail = "Trailing settled-payout market data could not be loaded.";
  } else if (!hasFittingModel) {
    unavailableDetail = `No active public model fits in ${effectiveRAM} GB.`;
  } else if (!result) {
    unavailableDetail =
      "No fitting model has both settled payout and live supply benchmark data.";
  }

  return (
    <div className="rounded-xl bg-bg-secondary p-6 sm:p-8 mb-6 text-center">
      <p className="text-xs uppercase tracking-wider text-text-secondary mb-2">
        Estimated annual net earnings
      </p>

      {loading && (
        <>
          <p className="text-4xl sm:text-5xl font-bold font-mono text-text-primary py-2">…</p>
          <p className="text-sm text-text-secondary">Loading the trailing market window…</p>
        </>
      )}
      {!loading && result && (
        <>
          <p className="text-4xl sm:text-5xl font-bold font-mono text-text-primary py-1">
            {fmtUSD(result.annualNetUSD)}
            <span className="text-lg font-normal text-text-secondary"> /yr</span>
          </p>
          <p className="text-sm text-text-secondary mt-1">
            {fmtUSD(result.monthlyNetUSD)} per month after electricity
          </p>
        </>
      )}
      {!loading && !result && (
        <>
          <p className="text-3xl sm:text-4xl font-bold text-text-primary py-2">
            Estimate unavailable
          </p>
          <p className="text-sm text-text-secondary">{unavailableDetail}</p>
        </>
      )}

      {result && bestModel && (
        <div className="mt-4 flex flex-col sm:flex-row items-stretch sm:items-center justify-center gap-2 sm:gap-3">
          <div className="flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg bg-accent-green/10 text-sm text-text-primary">
            <TrendingUp size={14} className="text-accent-green shrink-0" />
            <span>
              <span className="font-mono font-medium">{fmtUSD(result.workPayoutUSD)}/mo</span>{" "}
              candidate share for {bestModel.display_name}
            </span>
          </div>
          {result.baseRewardPotentialUSD > 0 && (
            <div className="flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg bg-accent-brand/10 text-sm text-text-primary">
              <Shield size={14} className="text-accent-brand shrink-0" />
              <span>
                up to{" "}
                <span className="font-mono font-medium">
                  {fmtUSD(result.baseRewardPotentialUSD)}/mo
                </span>{" "}
                base reward before eligibility and pool allocation
              </span>
            </div>
          )}
        </div>
      )}

      {marketState === "ready" && !hasFittingModel && (
        <SmallModelsInterest
          calc={calc}
          authenticated={authenticated}
          ready={ready}
          login={login}
        />
      )}

      {result && market && (
        <div className="mt-4 flex items-start gap-2 text-left rounded-lg bg-bg-tertiary px-3 py-2.5">
          <Info size={14} className="text-text-secondary shrink-0 mt-0.5" aria-hidden />
          <p className="text-xs text-text-secondary">
            This uses the fixed trailing {market.window_days}-day settled work pool and full-month
            availability; it is not a promise. Demand and competing capacity change. The base
            reward is eligibility-gated and shared from a fixed pool, so the memory-tier amount
            is a maximum, not guaranteed income.
          </p>
        </div>
      )}
    </div>
  );
}
