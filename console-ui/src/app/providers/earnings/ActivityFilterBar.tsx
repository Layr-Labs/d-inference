"use client";

// "Recent activity" heading plus the two global filters (model, time range)
// that drive both the chart and the activity list below it.

import { BASE_REWARD_MODEL, TIME_RANGES } from "./aggregate";

const SELECT_CLASS =
  "rounded-lg border border-border-default bg-bg-secondary text-xs text-text-secondary px-3 py-1.5 focus:outline-none focus:ring-1 focus:ring-accent-brand";

export function ActivityFilterBar({
  models,
  selectedModel,
  onSelectModel,
  rangeDays,
  onSelectRange,
}: {
  /** Model ids for the filter dropdown, most-earned first. */
  models: string[];
  /** Currently selected model, or "" for all models. */
  selectedModel: string;
  onSelectModel: (model: string) => void;
  /** Look-back window in days; 0 means all time. */
  rangeDays: number;
  onSelectRange: (days: number) => void;
}) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <h3 className="text-sm font-semibold text-text-primary mr-auto">
        Recent activity
      </h3>
      {models.length > 1 && (
        <select
          aria-label="Filter by model"
          value={selectedModel}
          onChange={(e) => onSelectModel(e.target.value)}
          className={`min-w-0 max-w-[14rem] truncate ${SELECT_CLASS}`}
        >
          <option value="">All models</option>
          {models.map((m) => (
            <option key={m} value={m}>
              {m === BASE_REWARD_MODEL ? "Base reward" : m}
            </option>
          ))}
        </select>
      )}
      <select
        aria-label="Filter by time range"
        value={rangeDays}
        onChange={(e) => onSelectRange(Number(e.target.value))}
        className={`shrink-0 ${SELECT_CLASS}`}
      >
        {TIME_RANGES.map((r) => (
          <option key={r.days} value={r.days}>
            {r.label}
          </option>
        ))}
      </select>
    </div>
  );
}
