"use client";

import { ChevronDown, Cpu, Gauge, Layers, Percent, Tag, Timer } from "lucide-react";
import { DECODE_BANDWIDTH_EFFICIENCY, fmtUSD } from "./calc";
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
  const steps = [
    {
      icon: Layers,
      label: "1. Model that fits",
      value: bestModel.displayName,
      detail: `${bestModel.minRAMGB} GB minimum memory · ${bestModel.sizeGB.toFixed(1)} GB model weights`,
    },
    {
      icon: Cpu,
      label: "2. Chip memory bandwidth",
      value: `${calc.hardware.bandwidthGBs} GB/s`,
      detail: `${calc.hardware.chip} peak unified-memory bandwidth`,
    },
    {
      icon: Gauge,
      label: "3. Single-stream decode speed",
      value: `${result.decodeTokensPerSecond.toFixed(1)} tok/s`,
      detail: `${calc.hardware.bandwidthGBs} GB/s × ${(DECODE_BANDWIDTH_EFFICIENCY * 100).toFixed(0)}% ÷ ${result.activeWeightGBPerToken.toFixed(2)} GB/token (${activeBillions.toFixed(1)}B active params)`,
    },
    {
      icon: Percent,
      label: "4. Duty cycle",
      value: `${calc.dutyCyclePercent}%`,
      detail: `${(result.activeSecondsPerMonth / 3600).toFixed(0)} active hours per 30-day month`,
    },
    {
      icon: Timer,
      label: "5. Output capacity",
      value: `${formatTokens(result.outputTokensPerMonth)} tokens/mo`,
      detail: "One sequence at a time, with no batching",
    },
    {
      icon: Tag,
      label: "6. OpenRouter output pricing",
      value: `${fmtUSD(result.outputPriceUSDPerMillion, 3)} / 1M tokens`,
      detail: `Applied to ${formatTokens(result.outputTokensPerMonth)} output tokens per month`,
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
            The estimate assumes bandwidth-limited, single-stream decoding, with duty cycle as the
            only adjustable input.
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
