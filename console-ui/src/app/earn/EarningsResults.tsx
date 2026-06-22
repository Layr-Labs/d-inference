"use client";

import {
  DollarSign,
  TrendingUp,
  Coffee,
  Wifi,
  ParkingCircle,
  Info,
  Shield,
} from "lucide-react";
import { BaseRewardsPanel } from "@/components/earn/BaseRewardsPanel";
import {
  type MacConfig,
  fmtUSD,
  fmtUSDWhole,
  SINGLE_STREAM_EFFICIENCY,
  CONTINUOUS_BATCH_FACTOR,
  ASSUMED_UTILIZATION,
  PROMPT_TO_COMPLETION_RATIO,
} from "./calc";
import type { EarningsCalculator } from "./useEarningsCalculator";

function comparisonIcon(text: string) {
  if (text.includes("Spotify") || text.includes("Netflix"))
    return <TrendingUp size={14} className="text-accent-green shrink-0" />;
  if (text.includes("latte")) return <Coffee size={14} className="text-accent-amber shrink-0" />;
  if (text.includes("internet")) return <Wifi size={14} className="text-accent-brand shrink-0" />;
  if (text.includes("parking"))
    return <ParkingCircle size={14} className="text-accent-amber shrink-0" />;
  return <DollarSign size={14} className="text-accent-green shrink-0" />;
}

export function EarningsResults({
  calc,
  config,
}: {
  calc: EarningsCalculator;
  config: MacConfig;
}) {
  const { result, effectiveRAM, elecCost, elecCostNum, setElecCost, comparisons } = calc;

  if (!result) {
    return (
      <div className="rounded-xl bg-bg-secondary p-6 mb-6">
        <div className="flex items-start gap-3">
          <div className="w-8 h-8 rounded-lg bg-accent-amber/10 border border-accent-amber/20 flex items-center justify-center shrink-0">
            <Info size={14} className="text-accent-amber" />
          </div>
          <div>
            <h3 className="text-sm font-medium text-text-primary mb-1">
              No compatible model for this hardware
            </h3>
            <p className="text-sm text-text-tertiary">
              No live catalog model fits in {effectiveRAM} GB of unified memory. Choose a Mac with more memory to estimate provider earnings.
            </p>
          </div>
        </div>
      </div>
    );
  }

  return (
    <>
      {/* Electricity cost (utilization & hours are fixed at 100% / always-on) */}
      <div className="rounded-xl bg-bg-secondary p-5 mb-6">
        <label className="block text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
          <DollarSign size={12} className="inline mr-1.5 -mt-0.5" />
          Electricity Cost
        </label>
        <div className="flex items-baseline gap-2">
          <span className="text-text-secondary text-sm">$</span>
          <input
            type="number"
            step="0.01"
            min="0"
            value={elecCost}
            onChange={(e) => setElecCost(e.target.value)}
            className="w-24 bg-bg-tertiary rounded-lg px-3 py-2 text-sm font-mono text-text-primary focus:outline-none focus:ring-2 focus:ring-accent-brand/50"
          />
          <span className="text-text-tertiary text-sm">/kWh</span>
        </div>
        <p className="text-xs text-text-tertiary mt-2">
          US avg: $0.15 | EU avg: $0.25 | CA avg: $0.22
        </p>
      </div>

      {/* Results */}
      <div className="rounded-xl bg-bg-secondary p-6 mb-6">
        <div className="flex items-center gap-2 mb-5">
          <div className="w-8 h-8 rounded-lg bg-accent-green/10 border border-accent-green/20 flex items-center justify-center">
            <TrendingUp size={14} className="text-accent-green" />
          </div>
          <div>
            <h3 className="text-sm font-medium text-text-primary">Estimated Earnings</h3>
            <p className="text-xs text-text-tertiary">
              Serving{" "}
              <span className="font-mono text-text-secondary">{result.modelName}</span>{" "}
              (always-on, {Math.round(ASSUMED_UTILIZATION * 100)}% utilization)
            </p>
            {result.selectedModelCount > 1 && (
              <p className="text-xs text-text-tertiary mt-1">
                Active time is split across selected models to avoid double-counting bandwidth and compute.
              </p>
            )}
          </div>
        </div>

        <div className="flex items-start gap-2 px-3 py-2.5 rounded-lg bg-bg-tertiary mb-5">
          <Info size={14} className="text-text-tertiary shrink-0 mt-0.5" />
          <p className="text-xs text-text-tertiary">
            Usage assumes <span className="text-text-secondary font-medium">{Math.round(ASSUMED_UTILIZATION * 100)}% utilization</span>{" "}
            with continuous batching ({CONTINUOUS_BATCH_FACTOR}× concurrent requests at full speed).
            Real demand varies by model and time of day — the base reward covers you while the
            network is quiet, and usage scales up as it fills.
          </p>
        </div>

        <div className="text-center py-6 border-b border-border-dim mb-6">
          <p className="text-xs uppercase tracking-wider text-text-tertiary mb-1">
            Monthly net earnings
          </p>
          <p className="text-4xl font-bold font-mono text-accent-green">
            {fmtUSDWhole(result.monthlyNet)}
          </p>
          <p className="text-sm text-text-tertiary mt-1">
            {fmtUSDWhole(result.annualNet)} / year
          </p>
        </div>

        <div className="grid grid-cols-3 gap-3 mb-6">
          <div className="rounded-lg bg-bg-tertiary p-3 text-center">
            <p className="text-xs text-text-tertiary mb-1">Usage (inference)</p>
            <p className="text-lg font-mono text-text-primary">{fmtUSD(result.monthlyUsageNet)}</p>
            <p className="text-[10px] text-text-tertiary mt-0.5">revenue − electricity</p>
          </div>
          <div className="rounded-lg bg-accent-brand/5 border border-accent-brand/20 p-3 text-center">
            <p className="text-xs text-text-tertiary mb-1 flex items-center justify-center gap-1">
              <Shield size={11} className="text-accent-brand" /> Base reward
            </p>
            <p className="text-lg font-mono text-accent-brand">+ {fmtUSD(result.monthlyFloor)}</p>
            <p className="text-[10px] text-text-tertiary mt-0.5">{effectiveRAM}GB tier × uptime</p>
          </div>
          <div className="rounded-lg bg-accent-green/5 border border-accent-green/20 p-3 text-center">
            <p className="text-xs text-text-tertiary mb-1">Total / mo</p>
            <p className="text-lg font-mono text-accent-green">{fmtUSD(result.monthlyNet)}</p>
            <p className="text-[10px] text-text-tertiary mt-0.5">usage + base reward</p>
          </div>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div>
            <p className="text-xs text-text-tertiary mb-0.5">Decode speed</p>
            <p className="text-sm font-mono text-text-primary">{result.decodeTokPerSec.toFixed(1)} tok/s</p>
          </div>
          <div>
            <p className="text-xs text-text-tertiary mb-0.5">Monthly usage revenue</p>
            <p className="text-sm font-mono text-text-primary">{fmtUSD(result.monthlyRevenue)}</p>
          </div>
          <div>
            <p className="text-xs text-text-tertiary mb-0.5">Monthly electricity</p>
            <p className="text-sm font-mono text-accent-red">-{fmtUSD(result.monthlyElec)}</p>
          </div>
          <div>
            <p className="text-xs text-text-tertiary mb-0.5">Electricity % of revenue</p>
            <p className="text-sm font-mono text-text-primary">{result.elecPercent.toFixed(1)}%</p>
          </div>
          <div>
            <p className="text-xs text-text-tertiary mb-0.5">Usage revenue per hour</p>
            <p className="text-sm font-mono text-text-primary">{fmtUSD(result.revenuePerHour, 4)}</p>
          </div>
          <div>
            <p className="text-xs text-text-tertiary mb-0.5">Electricity per hour</p>
            <p className="text-sm font-mono text-text-secondary">{fmtUSD(result.elecPerHour, 4)}</p>
          </div>
          <div>
            <p className="text-xs text-text-tertiary mb-0.5">Base reward / mo</p>
            <p className="text-sm font-mono text-accent-brand">{fmtUSD(result.monthlyFloor)}</p>
          </div>
          <div>
            <p className="text-xs text-text-tertiary mb-0.5 flex items-center gap-1">
              Provider share
              <span className="relative group">
                <Info size={12} className="text-text-tertiary cursor-help" />
                <span className="absolute bottom-full left-1/2 -translate-x-1/2 mb-1 w-48 px-2 py-1 text-[10px] text-text-secondary bg-bg-tertiary border border-border-primary rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-10">
                  You keep 100% of usage revenue and the base reward. Payouts are currently processed manually.
                </span>
              </span>
            </p>
            <p className="text-sm font-mono text-text-primary">100%</p>
          </div>
        </div>
      </div>

      <BaseRewardsPanel highlightGB={effectiveRAM} />

      {/* Calculation breakdown */}
      <div className="rounded-xl bg-bg-secondary p-6 mb-6">
        <h3 className="text-sm font-medium text-text-primary mb-3">How this is calculated</h3>
        <div className="text-xs text-text-tertiary font-mono space-y-1 bg-bg-tertiary rounded-lg p-4 overflow-x-auto">
          {result.selectedModels[0] && (
            <>
              <p>
                single_stream = ({config.bandwidthGBs} GB/s / {result.selectedModels[0].activeParamsGB} GB) * {SINGLE_STREAM_EFFICIENCY} ={" "}
                {((config.bandwidthGBs / result.selectedModels[0].activeParamsGB) * SINGLE_STREAM_EFFICIENCY).toFixed(1)} tok/s
              </p>
              <p>
                decode_tok/s = single_stream * {CONTINUOUS_BATCH_FACTOR}x batch * {Math.round(ASSUMED_UTILIZATION * 100)}% util ={" "}
                {result.selectedModels[0].decodeTokPerSec.toFixed(1)} tok/s
              </p>
              <p>
                usage_rev/hr = decode_tok/hr * out_price + (decode_tok/hr * {PROMPT_TO_COMPLETION_RATIO} prompt) * in_price ={" "}
                {fmtUSD(result.revenuePerHour, 4)}
              </p>
              <p>
                electricity/hr = ({result.selectedModels[0].marginalWatts}W / 1000) * ${elecCostNum.toFixed(2)}/kWh * {Math.round(ASSUMED_UTILIZATION * 100)}% ={" "}
                {fmtUSD(result.elecPerHour, 4)}
              </p>
              <p>
                monthly_usage = ({fmtUSD(result.revenuePerHour, 4)} - {fmtUSD(result.elecPerHour, 4)}) * 24 hrs/day * 30 ={" "}
                {fmtUSD(result.monthlyUsageNet)}
              </p>
              <p>
                base_reward = {effectiveRAM}GB tier * 100% uptime = {fmtUSD(result.monthlyFloor)}/mo
              </p>
              <p className="text-text-secondary">
                monthly_total = {fmtUSD(result.monthlyUsageNet)} usage + {fmtUSD(result.monthlyFloor)} base reward ={" "}
                {fmtUSD(result.monthlyNet)}
              </p>
            </>
          )}
        </div>
      </div>

      {comparisons.length > 0 && (
        <div className="rounded-xl bg-bg-secondary p-6 mb-8">
          <h3 className="text-sm font-medium text-text-primary mb-3">Your Mac earns more than...</h3>
          <div className="space-y-2">
            {comparisons.map((c) => (
              <div
                key={c}
                className="flex items-center gap-3 px-3 py-2 rounded-lg bg-bg-tertiary text-sm text-text-secondary"
              >
                {comparisonIcon(c)}
                <span>{c}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </>
  );
}
