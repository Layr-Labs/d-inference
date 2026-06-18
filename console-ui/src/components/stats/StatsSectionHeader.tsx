"use client";

import type { ReactNode } from "react";
import { statsSectionIndex } from "./styles";

export type StatsHeaderMetric = {
  value: string;
  label: string;
};

interface StatsSectionHeaderProps {
  index: string;
  title: string;
  description: string;
  icon?: ReactNode;
  metrics?: StatsHeaderMetric[];
}

export function StatsSectionHeader({
  index,
  title,
  description,
  icon,
  metrics,
}: StatsSectionHeaderProps) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-4 border-b border-border-dim pb-4 sm:gap-6">
      <div className="flex min-w-0 items-start gap-4">
        <span className={statsSectionIndex} aria-hidden="true">
          {index}
        </span>
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            {icon && <span className="mt-0.5 inline-flex text-accent-brand">{icon}</span>}
            <h2 className="text-[1.05rem] font-bold tracking-tight text-text-primary">{title}</h2>
          </div>
          <p className="mt-1.5 max-w-[34rem] text-[0.78rem] leading-snug text-text-tertiary">{description}</p>
        </div>
      </div>
      {metrics && metrics.length > 0 && (
        <div className="flex flex-wrap gap-x-7 gap-y-3">
          {metrics.map((metric) => (
            <div key={metric.label} className="text-right">
              <p className="font-mono text-xl font-bold tracking-tight text-text-primary leading-none">
                {metric.value}
              </p>
              <p className="mt-1 font-mono text-[0.58rem] tracking-[0.16em] uppercase text-text-tertiary">
                {metric.label}
              </p>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
