"use client";

import { AlertTriangle } from "lucide-react";
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
  const { result, hasFittingModel, effectiveRAM, catalogState } = calc;
  const loading = catalogState === "loading";

  let unavailableDetail = "An earning estimate is unavailable for the models that fit this Mac.";
  if (catalogState === "unavailable") {
    unavailableDetail = "The current model catalog could not be loaded.";
  } else if (!hasFittingModel) {
    unavailableDetail = `No currently supported model fits in ${effectiveRAM} GB.`;
  }

  let statusContent = (
    <>
      <p className="mb-2 text-xs uppercase tracking-wider text-text-secondary">
        Estimated monthly earning
      </p>
      <p className="py-2 text-3xl font-bold text-text-primary sm:text-4xl">
        Estimate unavailable
      </p>
      <p className="text-sm text-text-secondary">{unavailableDetail}</p>
    </>
  );
  if (loading) {
    statusContent = (
      <>
        <p className="mb-2 text-xs uppercase tracking-wider text-text-secondary">
          Estimated monthly earning
        </p>
        <p className="py-2 font-mono text-4xl font-bold text-text-primary sm:text-5xl">…</p>
        <p className="text-sm text-text-secondary">Loading models…</p>
      </>
    );
  } else if (result) {
    statusContent = (
      <>
        <p className="text-xs uppercase tracking-wider text-text-secondary">
          Estimated monthly earning
        </p>
        <p className="py-1 font-mono text-4xl font-bold text-text-primary sm:text-5xl">
          {fmtUSD(result.monthlyRevenueUSD)}
          <span className="text-lg font-normal text-text-secondary"> /mo</span>
        </p>
        <p className="mt-1 text-sm text-text-secondary">
          {fmtUSD(result.annualRevenueUSD)}/yr at {calc.dutyCyclePercent}% duty cycle
        </p>
      </>
    );
  }

  return (
    <div className="mb-6 rounded-xl bg-bg-secondary p-6 text-center sm:p-8">
      <div role="status" aria-live="polite" aria-atomic="true">{statusContent}</div>

      {catalogState === "ready" && !hasFittingModel && (
        <SmallModelsInterest
          calc={calc}
          authenticated={authenticated}
          ready={ready}
          login={login}
        />
      )}

      {result && (
        <div
          role="note"
          className="mt-5 flex items-start gap-2.5 rounded-lg border border-accent-amber/30 bg-accent-amber-dim px-4 py-3 text-left"
        >
          <AlertTriangle
            size={16}
            className="mt-0.5 shrink-0 text-black"
            aria-hidden
          />
          <p className="text-[14.4px] leading-relaxed text-black">
            <strong>Estimated earning, not guaranteed.</strong>{" "}
            While the system is bootstrapping, we are seeing significant variation in earning
            levels among providers using the same machine type. The default duty cycle is 5% to
            reflect this.
          </p>
        </div>
      )}
    </div>
  );
}
