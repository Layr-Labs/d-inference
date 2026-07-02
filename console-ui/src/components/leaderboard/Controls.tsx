"use client";

import type { LeaderboardMetric, LeaderboardWindow } from "./types";

const WINDOW_OPTIONS: Array<{ value: LeaderboardWindow; label: string }> = [
  { value: "24h", label: "24h" },
  { value: "7d", label: "7d" },
  { value: "30d", label: "30d" },
  { value: "all", label: "All" },
];

const METRIC_OPTIONS: Array<{ value: LeaderboardMetric; label: string }> = [
  { value: "earnings", label: "Earnings" },
  { value: "tokens", label: "Tokens" },
  { value: "jobs", label: "Jobs" },
];

/** 24h / 7d / 30d / All rolling-window toggle. */
export function WindowToggle({
  window,
  onChange,
}: {
  window: LeaderboardWindow;
  onChange: (window: LeaderboardWindow) => void;
}) {
  return (
    <>
      {WINDOW_OPTIONS.map((option) => (
        <button
          key={option.value}
          type="button"
          onClick={() => onChange(option.value)}
          className={`rounded-lg border px-3 py-1.5 text-sm font-medium transition-colors ${
            window === option.value
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

/** Earnings / Tokens / Jobs ranking-metric toggle. */
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
              ? "border-accent-green/35 bg-accent-green/10 text-accent-green"
              : "border-border-dim bg-bg-secondary text-text-secondary hover:border-border-subtle hover:bg-bg-hover"
          }`}
        >
          {option.label}
        </button>
      ))}
    </>
  );
}
