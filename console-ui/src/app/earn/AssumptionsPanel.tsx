"use client";

import { ChevronDown } from "lucide-react";
import { DEFAULT_ELEC_COST_PER_KWH, MONTH_HOURS, fmtTokens, fmtUSD } from "./calc";
import type { EarningsCalculator } from "./useEarningsCalculator";

function CalcStep({
  label,
  detail,
  value,
  emphasize = false,
}: {
  label: string;
  detail: string;
  value: string;
  emphasize?: boolean;
}) {
  return (
    <div className="flex items-center justify-between gap-4 px-4 py-3">
      <div className="min-w-0">
        <p className={`text-sm ${emphasize ? "font-semibold text-text-primary" : "font-medium text-text-primary"}`}>
          {label}
        </p>
        <p className="text-xs text-text-secondary mt-0.5">{detail}</p>
      </div>
      <p
        className={`text-sm font-mono tabular-nums whitespace-nowrap ${
          emphasize ? "font-semibold text-text-primary" : "text-text-secondary"
        }`}
      >
        {value}
      </p>
    </div>
  );
}

export function AssumptionsPanel({ calc }: { calc: EarningsCalculator }) {
  const { result, market, hardware, effectiveRAM } = calc;
  if (!result || !market) return null;

  const model = result.model;
  const policy = market.base_rewards;
  const observedTPSPerBandwidth =
    model.benchmark_tps / model.benchmark_memory_bandwidth_gbps;
  const uptimePercent = Math.round(policy.min_uptime_fraction * 100);
  const basePoolUSD = policy.monthly_pool_micro_usd / 1_000_000;
  const unattributedPoolUSD = market.audit.unattributed_work_micro_usd / 1_000_000;
  const reductionDetail =
    policy.reduction_k > 0
      ? `; reduced by ${policy.reduction_k.toFixed(2)}× candidate work earnings`
      : "";
  const accountCapDetail =
    policy.account_cap_fraction > 0
      ? `; ${(policy.account_cap_fraction * 100).toFixed(1)}% per-account pool cap`
      : "";

  return (
    <details className="group rounded-xl bg-bg-secondary mb-6 open:pb-2">
      <summary className="flex items-center justify-between px-6 py-4 cursor-pointer list-none select-none">
        <span className="text-sm font-medium text-text-primary">
          How we estimate this
        </span>
        <ChevronDown
          size={16}
          className="text-text-secondary transition-transform group-open:rotate-180"
        />
      </summary>

      <div className="px-6 pb-4 space-y-5">
        <p className="text-sm text-text-secondary">
          The model&apos;s settled provider payouts form a fixed trailing 30-day work pool.
          Your candidate share is its estimated capacity divided by existing capacity plus
          that candidate. Adding a candidate reallocates the same pool; it does not manufacture
          new demand.
        </p>

        <div className="grid grid-cols-1 sm:grid-cols-4 gap-3">
          <div className="rounded-lg bg-bg-tertiary p-3 text-center">
            <p className="text-xs text-text-secondary mb-1">Candidate work share</p>
            <p className="text-lg font-mono text-text-primary">{fmtUSD(result.workPayoutUSD)}</p>
            <p className="text-xs text-text-secondary mt-0.5">from settled demand</p>
          </div>
          <div className="rounded-lg bg-accent-brand/5 border border-accent-brand/20 p-3 text-center">
            <p className="text-xs text-text-secondary mb-1">Base reward maximum</p>
            <p className="text-lg font-mono text-accent-brand">
              + {fmtUSD(result.baseRewardPotentialUSD)}
            </p>
            <p className="text-xs text-text-secondary mt-0.5">eligibility- and pool-capped</p>
          </div>
          <div className="rounded-lg bg-bg-tertiary p-3 text-center">
            <p className="text-xs text-text-secondary mb-1">Electricity</p>
            <p className="text-lg font-mono text-text-primary">
              − {fmtUSD(result.electricityUSD)}
            </p>
            <p className="text-xs text-text-secondary mt-0.5">idle + allocated work</p>
          </div>
          <div className="rounded-lg bg-accent-green/5 border border-accent-green/20 p-3 text-center">
            <p className="text-xs text-text-secondary mb-1">Estimated net / mo</p>
            <p className="text-lg font-mono text-text-primary">{fmtUSD(result.monthlyNetUSD)}</p>
            <p className="text-xs text-text-secondary mt-0.5">work + reward − power</p>
          </div>
        </div>

        <div className="rounded-lg border border-border-dim divide-y divide-border-dim">
          <CalcStep
            label="Trailing settled payout pool"
            detail={`${model.paid_jobs.toLocaleString()} paid ${model.display_name} jobs and ${fmtTokens(model.paid_tokens)} paid tokens in the fixed 30-day window`}
            value={`${fmtUSD(result.workPoolUSD)} / 30d`}
          />
          <CalcStep
            label="Competing live capacity"
            detail={`${model.provider_supply} eligible providers on the currently routed build; ${model.aggregate_memory_bandwidth_gbps.toFixed(0)} GB/s aggregate reported bandwidth`}
            value={`${model.aggregate_tps.toFixed(1)} tok/s`}
          />
          <CalcStep
            label="Candidate capacity"
            detail={`${model.benchmark_tps.toFixed(1)} observed tok/s ÷ ${model.benchmark_memory_bandwidth_gbps.toFixed(0)} GB/s × this Mac's ${hardware.bandwidthGBs} GB/s`}
            value={`${result.candidateTPS.toFixed(1)} tok/s`}
          />
          <CalcStep
            label="Candidate work payout"
            detail={`${fmtUSD(result.workPoolUSD)} × c/(S+c), a ${(result.candidateShare * 100).toFixed(2)}% capacity share; existing and candidate shares sum to the same pool`}
            value={`${fmtUSD(result.workPayoutUSD)} /mo`}
          />
          <CalcStep
            label="Electricity"
            detail={`${hardware.idleWatts}W online idle for ${MONTH_HOURS}h plus ${Math.max(0, hardware.inferWatts - hardware.idleWatts)}W workload draw for ${result.activeHours.toFixed(2)}h at $${DEFAULT_ELEC_COST_PER_KWH.toFixed(2)}/kWh`}
            value={`−${fmtUSD(result.electricityUSD)} /mo`}
          />
          <CalcStep
            label="Base reward maximum"
            detail={
              policy.enabled
                ? `${effectiveRAM} GB tier at full-month availability${reductionDetail}; requires attestation, health, and ≥${uptimePercent}% uptime, then shares the fixed ${fmtUSD(basePoolUSD)} monthly fleet pool${accountCapDetail}`
                : "Base rewards are currently disabled; tier policy does not create a payout"
            }
            value={`+${fmtUSD(result.baseRewardPotentialUSD)} /mo`}
          />
          <CalcStep
            label="Estimated net"
            detail="Candidate work payout + base reward maximum − idle and workload electricity"
            value={`${fmtUSD(result.monthlyNetUSD)} /mo`}
            emphasize
          />
        </div>

        <ul className="text-xs text-text-secondary space-y-1.5 list-disc pl-4">
          <li>
            Full-month availability is fixed. Power charges all online idle hours, then treats
            every allocated prompt and completion token as slower decode work and clamps active
            time to 720 hours.
          </li>
          <li>
            Base rewards are separate from work demand. The memory tier is only a maximum before
            configured work reduction, account caps, eligibility checks, and fixed-pool
            allocation; it is not committed or guaranteed.
          </li>
          <li>
            The audit reconciles {fmtUSD(market.audit.modeled_work_micro_usd / 1_000_000)} modeled
            work and {fmtUSD(unattributedPoolUSD)} unattributed work to{" "}
            {fmtUSD(market.audit.total_settled_work_micro_usd / 1_000_000)} total settled work.
          </li>
          <li>
            Actual routing also depends on uptime, trust, reputation, latency, and request shape.
          </li>
          <li>
            Observed capacity rate: {observedTPSPerBandwidth.toFixed(4)} tok/s per GB/s of memory
            bandwidth.
          </li>
        </ul>
      </div>
    </details>
  );
}
