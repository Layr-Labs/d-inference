"use client";

import type { LeaderboardMetric } from "./types";

const METRIC_OPTIONS: Array<{ value: LeaderboardMetric; label: string }> = [
  { value: "earnings", label: "Earnings" },
  { value: "tokens", label: "Tokens" },
];

/** Earnings / Tokens ranking-metric toggle. */
export function MetricToggle({
  metric,
  onChange,
}: {
  metric: LeaderboardMetric;
  onChange: (metric: LeaderboardMetric) => void;
}) {
  return (
    <>
      {METRIC_OPTIONS.map((option) => (
        <button
          key={option.value}
          type="button"
          onClick={() => onChange(option.value)}
          className={`rounded-lg border px-3 py-1.5 text-sm font-medium transition-colors ${
            metric === option.value
              ? "border-accent-brand/35 bg-accent-brand/10 text-accent-brand"
              : "border-border-dim bg-bg-secondary text-text-secondary hover:border-border-subtle hover:bg-bg-hover"
          }`}
        >
          {option.label}
        </button>
      ))}
    </>
  );
}
