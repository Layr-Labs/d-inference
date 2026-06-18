"use client";

import { statsMetricLabel, statsMetricSub, statsMetricValue, statsReveal3, statsSectionIndex } from "./styles";

interface HardwareMetric {
  label: string;
  value: string;
  unit?: string;
  sub?: string;
  power?: boolean;
}

export function StatsHardwareStrip({ metrics }: { metrics: HardwareMetric[] }) {
  return (
    <div className={`flex flex-col gap-2.5 ${statsReveal3}`}>
      <div className="flex items-center font-mono text-[0.62rem] tracking-[0.18em] uppercase text-text-tertiary">
        <span className={`${statsSectionIndex} mr-1.5 pt-0`}>05</span>
        <span>Fleet telemetry</span>
      </div>
      <div className="grid grid-cols-2 overflow-hidden rounded-[0.35rem] border border-border-dim bg-bg-primary shadow-sm sm:grid-cols-3 lg:grid-cols-6 divide-x divide-y divide-border-dim lg:divide-y-0">
        {metrics.map((metric) => (
          <div
            key={metric.label}
            className="bg-bg-primary p-4 transition-colors hover:bg-accent-brand-dim/55"
          >
            <p className={statsMetricLabel}>{metric.label}</p>
            <p
              className={`${statsMetricValue} flex flex-nowrap items-baseline gap-1 whitespace-nowrap text-[clamp(1.1rem,2.1vw,1.65rem)] ${
                metric.power ? "text-accent-amber" : ""
              }`}
            >
              <span>{metric.value}</span>
              {metric.unit && (
                <span className="text-[0.58em] font-semibold tracking-wide text-text-secondary">
                  {metric.unit}
                </span>
              )}
            </p>
            {metric.sub && <p className={statsMetricSub}>{metric.sub}</p>}
          </div>
        ))}
      </div>
    </div>
  );
}
