"use client";

import type { UsageEntry } from "@/lib/api";

interface Props {
  usage: UsageEntry[];
}

/** Group usage entries by day and render a simple bar chart using pure CSS. */
export function UsageChart({ usage }: Props) {
  if (usage.length === 0) return null;

  // Group by day
  const byDay = new Map<string, number>();
  for (const entry of usage) {
    const day = new Date(entry.timestamp).toLocaleDateString("en-US", {
      month: "short",
      day: "numeric",
    });
    byDay.set(day, (byDay.get(day) || 0) + entry.cost_micro_usd);
  }

  const days = Array.from(byDay.entries()).slice(-14); // last 14 days
  const maxCost = Math.max(...days.map(([, v]) => v), 1);

  return (
    <div className="rounded-xl border border-border-dim bg-bg-secondary p-5">
      <h3 className="text-sm font-medium text-text-primary mb-4">
        Spend Over Time
      </h3>
      <div className="flex items-end gap-1.5 h-32">
        {days.map(([day, cost]) => {
          const pct = Math.max((cost / maxCost) * 100, 4);
          return (
            <div
              key={day}
              className="flex-1 flex flex-col items-center gap-1 group"
            >
              {/* Tooltip */}
              <div className="opacity-0 group-hover:opacity-100 transition-opacity text-[10px] font-mono text-text-secondary whitespace-nowrap">
                ${(cost / 1_000_000).toFixed(4)}
              </div>
              {/* Bar */}
              <div className="w-full flex items-end justify-center" style={{ height: "100%" }}>
                <div
                  className="w-full max-w-[28px] rounded-t bg-accent-purple/60 hover:bg-accent-purple transition-colors"
                  style={{ height: `${pct}%` }}
                />
              </div>
              {/* Label */}
              <span className="text-[9px] font-mono text-text-tertiary truncate w-full text-center">
                {day}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
