// Per-machine operational stats: job counts + lifetime throughput +
// time-to-first-token. Tokens are per-box; the "Avg TTFT" stat reflects real
// time-to-first-token, not answer length. Account-wide earnings live in the
// fleet header, not on individual machine cards.

import type { MyProvider } from "../types";
import { abbreviateNumber, formatNumber, humanizeUptime } from "./format";

function Stat({
  label,
  value,
  sub,
}: {
  label: string;
  value: string;
  sub?: string;
}) {
  return (
    <div className="rounded-lg bg-bg-primary/50 p-2.5">
      <p className="text-[10px] uppercase tracking-wider text-text-tertiary">{label}</p>
      <p className="text-sm font-mono font-semibold text-text-primary mt-0.5 tabular-nums">{value}</p>
      {sub && <p className="text-[11px] text-text-tertiary mt-0.5">{sub}</p>}
    </div>
  );
}

export function CardEarningsRow({ provider }: { provider: MyProvider }) {
  const rep = provider.reputation;
  // avg_response_time_ms now holds an EWMA of real time-to-first-token (ms).
  const ttft = rep.avg_response_time_ms > 0 ? `${Math.round(rep.avg_response_time_ms)}ms` : "—";

  return (
    <div className="px-4 py-4 border-t border-border-dim/40 grid grid-cols-2 md:grid-cols-3 gap-2.5">
      <Stat
        label="Jobs"
        value={formatNumber(rep.total_jobs)}
        sub={`${formatNumber(rep.successful_jobs)} succeeded · ${formatNumber(rep.failed_jobs)} failed`}
      />
      <Stat
        label="Tokens"
        value={abbreviateNumber(provider.lifetime_tokens_generated)}
        sub={`${abbreviateNumber(provider.lifetime_requests_served)} reqs`}
      />
      <Stat label="Avg TTFT" value={ttft} sub={`up ${humanizeUptime(rep.total_uptime_seconds)}`} />
    </div>
  );
}
