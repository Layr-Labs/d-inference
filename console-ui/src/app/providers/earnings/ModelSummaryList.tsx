"use client";

// Per-model summary rows shown instead of the raw log. Clicking one drills
// into that model's paginated log in EarningsHistory.

import { Box, ChevronRight } from "lucide-react";
import type { ModelSummary } from "./aggregate";
import { formatMicroDollars, formatTokens, modelLabel } from "./format";
import { relativeTime } from "@/lib/format/time";

export function ModelSummaryList({
  summaries,
  onSelect,
}: {
  summaries: ModelSummary[];
  onSelect: (model: string) => void;
}) {
  const allModels = summaries.map((s) => s.model);
  return (
    <ul className="divide-y divide-border-dim/50">
      {summaries.map((s) => (
        <li key={s.model}>
          <button
            onClick={() => onSelect(s.model)}
            className="w-full flex items-center gap-3 px-4 py-3 text-left hover:bg-bg-hover transition-colors"
          >
            <Box size={16} className="shrink-0 text-accent-brand" />
            <span className="min-w-0 flex-1">
              <span
                className="block text-sm font-mono text-text-primary truncate"
                title={s.model}
              >
                {modelLabel(s.model, allModels)}
              </span>
              <span className="block text-xs text-text-tertiary">
                {s.jobs.toLocaleString("en-US")} jobs ·{" "}
                {formatTokens(s.tokens)} tokens · {relativeTime(s.lastActive)}
              </span>
            </span>
            <span className="text-sm font-mono text-accent-green whitespace-nowrap">
              +{formatMicroDollars(s.micro)}
            </span>
            <ChevronRight size={16} className="shrink-0 text-text-tertiary" />
          </button>
        </li>
      ))}
    </ul>
  );
}
