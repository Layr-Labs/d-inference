"use client";

import type { ReactNode } from "react";
import { Activity, BarChart3, CircleDollarSign, Users } from "lucide-react";
import type { NetworkTotalsResponse } from "./types";
import { formatEarningsBreakdown, formatNumber, formatUSDFromMicro } from "./format";

function TotalCard({
  icon,
  label,
  value,
  sub,
}: {
  icon: ReactNode;
  label: string;
  value: string;
  sub?: ReactNode;
}) {
  return (
    <div className="rounded-xl border border-border-dim bg-bg-secondary px-4 py-3">
      <div className="flex items-center gap-2 text-text-tertiary">
        {icon}
        <p className="text-[10px] font-mono uppercase tracking-wider">{label}</p>
      </div>
      <p className="mt-2 text-xl font-mono font-bold text-text-primary">{value}</p>
      {sub ? (
        <p className="mt-0.5 truncate text-[11px] font-mono text-text-tertiary">{sub}</p>
      ) : null}
    </div>
  );
}

/** Network-wide totals strip: earnings (with work/rewards split), tokens, jobs, accounts. */
export function TotalsStrip({ totals }: { totals: NetworkTotalsResponse | null }) {
  return (
    <div className="mt-5 grid grid-cols-2 gap-3 md:grid-cols-4">
      <TotalCard
        icon={<CircleDollarSign size={14} />}
        label="Total earnings"
        value={totals ? formatUSDFromMicro(totals.earnings_micro_usd) : "--"}
        sub={
          totals
            ? formatEarningsBreakdown(
                totals.work_earnings_micro_usd,
                totals.reward_earnings_micro_usd,
                formatUSDFromMicro,
              )
            : undefined
        }
      />
      <TotalCard
        icon={<BarChart3 size={14} />}
        label="Tokens served"
        value={totals ? formatNumber(totals.tokens) : "--"}
      />
      <TotalCard
        icon={<Activity size={14} />}
        label="Jobs"
        value={totals ? formatNumber(totals.jobs) : "--"}
      />
      <TotalCard
        icon={<Users size={14} />}
        label="Active accounts"
        value={totals ? formatNumber(totals.active_accounts) : "--"}
      />
    </div>
  );
}
