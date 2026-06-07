// The two-second glance: one verdict cell (is the whole fleet earning?) beside
// a segmented capacity bar and the money KPIs. Worst fleet state drives the
// left rail color so the page's health is signaled at the very top.

import { AlertTriangle, CheckCircle2, CircleSlash, XCircle, type LucideIcon } from "lucide-react";
import type { MySummaryResponse } from "../types";
import type { FleetVerdict } from "./aggregate";
import type { RoutingState } from "./routing";
import { routingMeta } from "./routing";
import { formatUSD } from "./format";
import { CapacityBar } from "./gauges/CapacityBar";

const ICON: Record<RoutingState, LucideIcon> = {
  routable: CheckCircle2,
  degraded: AlertTriangle,
  blocked: XCircle,
  offline: CircleSlash,
};

function KPI({
  label,
  value,
  sub,
  dot,
}: {
  label: string;
  value: string;
  sub?: string;
  dot?: boolean;
}) {
  return (
    <div>
      <p className="text-[10px] uppercase tracking-wider text-text-tertiary flex items-center gap-1">
        {dot && <span className="w-1.5 h-1.5 rounded-full bg-accent-green" />}
        {label}
      </p>
      <p className="text-2xl font-mono font-bold text-text-primary leading-tight mt-0.5 tabular-nums">{value}</p>
      {sub && <p className="text-[11px] text-text-tertiary">{sub}</p>}
    </div>
  );
}

export function FleetHealthStrip({
  verdict,
  summary,
}: {
  verdict: FleetVerdict;
  summary: MySummaryResponse | null;
}) {
  const meta = routingMeta(verdict.state);
  const Icon = ICON[verdict.state];

  return (
    <div className={`rounded-xl bg-bg-secondary shadow-sm border border-border-dim border-l-[3px] ${meta.rail} p-5`}>
      <div className="grid gap-5 lg:grid-cols-[36%_1fr] lg:items-center">
        {/* Left: the plain-language fleet verdict (worst state wins) */}
        <div className="flex items-center gap-3">
          <div className={`w-14 h-14 rounded-full flex items-center justify-center shrink-0 ${meta.tint}`}>
            <Icon size={26} className={meta.color} />
          </div>
          <div className="min-w-0">
            <p className={`text-lg font-bold leading-tight ${meta.color}`}>{verdict.headline}</p>
            <p className="text-xs text-text-secondary mt-0.5">{verdict.sub}</p>
          </div>
        </div>

        {/* Right: segmented capacity bar over the money + routable KPIs */}
        <div className="space-y-4">
          <CapacityBar counts={verdict.counts} />
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
            <KPI
              label="Last 24h"
              value={summary ? formatUSD(summary.last_24h_micro_usd) : "—"}
              sub={summary ? `${summary.last_24h_jobs} jobs` : undefined}
            />
            <KPI
              label="Last 7d"
              value={summary ? formatUSD(summary.last_7d_micro_usd) : "—"}
              sub={summary ? `${summary.last_7d_jobs} jobs` : undefined}
            />
            <KPI
              label="Withdrawable"
              value={summary ? formatUSD(summary.withdrawable_balance_micro_usd ?? summary.available_balance_micro_usd) : "—"}
              sub={summary?.payout_ready ? "payout ready" : "set up payouts"}
              dot={summary?.payout_ready}
            />
            <KPI
              label="Earning now"
              value={`${verdict.counts.routable + verdict.counts.degraded}/${verdict.counts.total}`}
              sub={verdict.counts.degraded > 0 ? `${verdict.counts.routable} full priority` : "machines routable"}
            />
          </div>
        </div>
      </div>
    </div>
  );
}
