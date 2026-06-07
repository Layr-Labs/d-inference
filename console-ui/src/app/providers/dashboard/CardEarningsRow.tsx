// Earnings + reputation + lifetime throughput + responsiveness for one
// machine. Money sits first and is always visible (never behind a toggle).

import type { MyProvider } from "../types";
import { abbreviateNumber, formatUSD, humanizeUptime } from "./format";
import { RatingPips } from "./gauges/RatingPips";

function Stat({
  label,
  value,
  sub,
  children,
}: {
  label: string;
  value: string;
  sub?: string;
  children?: React.ReactNode;
}) {
  return (
    <div className="rounded-lg bg-bg-primary/50 p-2.5">
      <p className="text-[10px] uppercase tracking-wider text-text-tertiary">{label}</p>
      <p className="text-sm font-mono font-semibold text-text-primary mt-0.5 tabular-nums">{value}</p>
      {children}
      {sub && <p className="text-[11px] text-text-tertiary mt-0.5">{sub}</p>}
    </div>
  );
}

export function CardEarningsRow({ provider }: { provider: MyProvider }) {
  const rep = provider.reputation;
  const latency = rep.avg_response_time_ms > 0 ? `${Math.round(rep.avg_response_time_ms)}ms` : "—";

  return (
    <div className="px-4 py-4 border-t border-border-dim/40 grid grid-cols-2 md:grid-cols-4 gap-2.5">
      <Stat
        label="Earnings"
        value={formatUSD(provider.earnings_total_micro_usd)}
        sub={`${abbreviateNumber(provider.earnings_count)} jobs`}
      />
      <Stat label="Reputation" value={rep.score.toFixed(2)} sub={`${rep.successful_jobs}/${rep.total_jobs || 0} ok`}>
        <div className="mt-1">
          <RatingPips score={rep.score} />
        </div>
      </Stat>
      <Stat
        label="Tokens"
        value={abbreviateNumber(provider.lifetime_tokens_generated)}
        sub={`${abbreviateNumber(provider.lifetime_requests_served)} reqs`}
      />
      <Stat label="Avg latency" value={latency} sub={`up ${humanizeUptime(rep.total_uptime_seconds)}`} />
    </div>
  );
}
