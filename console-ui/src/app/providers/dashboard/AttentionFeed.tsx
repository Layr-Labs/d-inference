"use client";

// The aggregated, deduped action-items feed — the answer to "which machine is
// broken, why, and what do I do?" without scrolling card by card. When the
// fleet is fully healthy it collapses to a single green all-clear strip.

import { useState } from "react";
import { CheckCircle2 } from "lucide-react";
import type { AttentionGroup } from "./aggregate";
import { SEVERITY_RANK } from "./routing";
import { AttentionItem } from "./AttentionItem";

type Filter = "all" | "blocking" | "degrading";

const MAX_RANK: Record<Filter, number> = { all: 2, degrading: 1, blocking: 0 };

export function AttentionFeed({ groups }: { groups: AttentionGroup[] }) {
  const [filter, setFilter] = useState<Filter>("all");

  if (groups.length === 0) {
    return (
      <div className="rounded-xl bg-accent-green/8 border border-accent-green/20 p-4 flex items-center gap-3">
        <CheckCircle2 size={18} className="text-accent-green shrink-0" />
        <p className="text-sm font-medium text-text-primary">
          All clear — every machine is routable and earning.
        </p>
      </div>
    );
  }

  const blockingCount = groups.filter((g) => g.severity === "blocking").length;
  const degradingCount = groups.filter((g) => g.severity === "degrading").length;
  const visible = groups.filter((g) => SEVERITY_RANK[g.severity] <= MAX_RANK[filter]);

  const tabs: { id: Filter; label: string; n: number }[] = [
    { id: "all", label: "All", n: groups.length },
    { id: "blocking", label: "Blocking", n: blockingCount },
    { id: "degrading", label: "Degrading", n: degradingCount },
  ];

  return (
    <div className="rounded-xl bg-bg-secondary shadow-sm border border-border-dim overflow-hidden">
      <div className="flex items-center justify-between gap-3 px-4 py-3 border-b border-border-dim/60 flex-wrap">
        <div className="flex items-center gap-2">
          <h3 className="text-sm font-semibold text-text-primary">Needs attention</h3>
          <span className="px-1.5 py-0.5 rounded-full bg-bg-tertiary text-[11px] font-mono text-text-secondary">
            {groups.length}
          </span>
        </div>
        <div className="flex items-center gap-1">
          {tabs.map((t) => (
            <button
              key={t.id}
              type="button"
              aria-pressed={filter === t.id}
              onClick={() => setFilter(t.id)}
              className={`focus-ring px-2.5 py-1 rounded-md text-xs font-medium transition-colors ${
                filter === t.id
                  ? "bg-accent-brand/10 text-accent-brand"
                  : "text-text-tertiary hover:text-text-secondary hover:bg-bg-hover"
              }`}
            >
              {t.label}
              {t.n > 0 && <span className="ml-1 font-mono opacity-70">{t.n}</span>}
            </button>
          ))}
        </div>
      </div>

      <div className="divide-y divide-border-dim/50">
        {visible.length > 0 ? (
          visible.map((g) => <AttentionItem key={g.id} group={g} />)
        ) : (
          <p className="px-4 py-6 text-sm text-text-tertiary text-center">No {filter} issues.</p>
        )}
      </div>
    </div>
  );
}
