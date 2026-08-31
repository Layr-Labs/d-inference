"use client";

// One earnings history row.

import { Box } from "lucide-react";
import type { Earning } from "./types";
import { formatMicroExact, formatRowTime, formatTokens } from "./format";

export function EarningsRow({ earning, label }: { earning: Earning; label: string }) {
  return (
    <tr className="border-b border-border-dim/50 last:border-0">
      <td className="px-4 py-3 text-sm font-mono text-text-primary">
        <span className="flex items-center gap-2 min-w-0">
          <Box size={14} className="shrink-0 text-accent-brand" />
          <span className="truncate max-w-[16rem]" title={earning.model}>
            {label}
          </span>
        </span>
      </td>
      <td className="px-4 py-3 text-sm font-mono text-accent-green whitespace-nowrap">
        +{formatMicroExact(earning.amount_micro_usd)}
      </td>
      <td className="px-4 py-3 text-sm font-mono text-text-secondary whitespace-nowrap">
        {formatTokens(earning.prompt_tokens + earning.completion_tokens)}{" "}
        <span className="text-xs text-text-tertiary">
          ({formatTokens(earning.completion_tokens)} completion)
        </span>
      </td>
      <td className="px-4 py-3 text-sm text-text-tertiary whitespace-nowrap">
        {formatRowTime(earning.created_at)}
      </td>
    </tr>
  );
}
