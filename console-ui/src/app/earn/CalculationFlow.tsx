"use client";

import { ChevronDown, Cpu, Gauge, Layers, Percent, Tag, Timer, Users } from "lucide-react";
import { ENGINE_MAX_CONCURRENT, fmtUSD } from "./calc";
import type { EarningsCalculator } from "./useEarningsCalculator";

function formatTokens(tokens: number): string {
  return new Intl.NumberFormat(undefined, {
    notation: "compact",
    maximumFractionDigits: 2,
  }).format(tokens);
}

export function CalculationFlow({ calc }: { calc: EarningsCalculator }) {
  const { result, bestModel } = calc;
  if (!result || !bestModel) return null;

  const activeBillions = bestModel.activeParameterCount / 1_000_000_000;
  const totalBillions = bestModel.totalParameterCount / 1_000_000_000;
  const steps = [
    {
      icon: Layers,
      label: "1. Model that fits",
      value: bestModel.displayName,
      detail: `${bestModel.minRAMGB} GB minimum memory · ${bestModel.sizeGB.toFixed(1)} GB weights · ${activeBillions.toFixed(1)}B of ${totalBillions.toFixed(0)}B params active`,
    },
    {
      icon: Cpu,
      label: "2. Chip memory bandwidth",
      value: `${calc.hardware.bandwidthGBs} GB/s`,
      detail: `${calc.hardware.chip} peak unified-memory bandwidth`,
    },
    {
      icon: Gauge,
      label: "3. Prefill and decode speed",
      value: `${result.prefillTokensPerSecond.toFixed(0)} / ${result.decodeTokensPerSecond.toFixed(1)} tok/s`,
      detail: `Single-stream prefill and decode. Decode is bandwidth-limited at ${(bestModel.decodeBandwidthEfficiency * 100).toFixed(0)}% of pin rate over ${result.activeWeightGBPerToken.toFixed(2)} GB active weights. Prefill is modeled at 12× decode, matching measured Gemma M4 Max rooflines.`,
    },
    {
      icon: Users,
      label: "4. Concurrency this Mac can hold",
      value: `${result.maxConcurrency} sequences`,
      detail: `Engine cap ${ENGINE_MAX_CONCURRENT}. KV budget ${formatTokens(result.tokenBudget)} tokens after weights and the 5.5 GiB activation reserve. A typical request is ${result.typicalPromptTokens.toLocaleString()} prompt + ${result.typicalCompletionTokens.toLocaleString()} completion tokens. At ${calc.dutyCyclePercent}% duty, estimated overlap is ${result.effectiveConcurrency.toFixed(2)} wide (${result.batchedPrefillTokensPerSecond.toFixed(0)} / ${result.batchedDecodeTokensPerSecond.toFixed(1)} tok/s batched).`,
    },
    {
      icon: Percent,
      label: "5. Duty cycle",
      value: `${calc.dutyCyclePercent}%`,
      detail: `${(result.activeSecondsPerMonth / 3600).toFixed(0)} serving hours per 30-day month. Higher duty also assumes more overlapping requests.`,
    },
    {
      icon: Timer,
      label: "6. Monthly token volume",
      value: `${formatTokens(result.promptTokensPerMonth)} in · ${formatTokens(result.outputTokensPerMonth)} out`,
      detail: "From the live network mix of about 3,200 prompt tokens and 400 completion tokens per request.",
    },
    {
      icon: Tag,
      label: "7. Input and output pricing",
      value: `${fmtUSD(result.inputPriceUSDPerMillion, 3)} / ${fmtUSD(result.outputPriceUSDPerMillion, 3)} per 1M`,
      detail: `${fmtUSD(result.inputRevenueUSD)} from prefill + ${fmtUSD(result.outputRevenueUSD)} from decode. Platform fee is 0% during public alpha.`,
    },
  ];

  return (
    <details className="group mb-6 overflow-hidden rounded-xl border border-border-dim bg-bg-secondary">
      <summary className="flex cursor-pointer list-none items-center justify-between gap-4 px-5 py-4 marker:content-none group-open:border-b group-open:border-border-dim">
        <span>
          <span className="block text-sm font-semibold text-text-primary">
            How this estimate is calculated
          </span>
          <span className="mt-1 block text-xs text-text-secondary">
            Prefill, decode, and KV-limited concurrency. Duty cycle is the only
            adjustable input.
          </span>
        </span>
        <ChevronDown
          size={18}
          className="shrink-0 text-text-secondary transition-transform group-open:rotate-180"
          aria-hidden
        />
      </summary>
      <ol>
        {steps.map((step) => {
          const Icon = step.icon;
          return (
            <li
              key={step.label}
              className="flex items-start gap-3 border-b border-border-dim px-5 py-4 last:border-b-0"
            >
              <div className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-bg-tertiary">
                <Icon size={15} className="text-accent-brand" aria-hidden />
              </div>
              <div className="min-w-0 flex-1">
                <p className="text-xs font-medium text-text-secondary">{step.label}</p>
                <p className="mt-0.5 font-mono text-sm font-semibold text-text-primary">
                  {step.value}
                </p>
                <p className="mt-1 text-xs leading-relaxed text-text-tertiary">{step.detail}</p>
              </div>
            </li>
          );
        })}
      </ol>
    </details>
  );
}
