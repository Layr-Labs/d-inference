"use client";

import { statsFlowTickerCell } from "./styles";

interface StatsFlowMetricProps {
  label: string;
  value: string;
  sub: string;
}

export function StatsFlowMetric({ label, value, sub }: StatsFlowMetricProps) {
  return (
    <div className={statsFlowTickerCell}>
      <p className="font-mono text-[0.56rem] tracking-[0.16em] uppercase text-text-tertiary">{label}</p>
      <p className="mt-1.5 font-mono text-lg font-bold tracking-tight text-text-primary leading-none">
        {value}
      </p>
      <p className="mt-1 truncate font-mono text-[0.62rem] text-text-tertiary">{sub}</p>
    </div>
  );
}
