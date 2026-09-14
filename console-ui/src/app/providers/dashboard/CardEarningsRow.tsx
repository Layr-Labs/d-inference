// Per-machine lifetime activity and measured time to first token.
import type { MyProvider } from "../types";
import { abbreviateNumber, humanizeUptime } from "./format";

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
      <Stat label="Requests served" value={abbreviateNumber(provider.lifetime_requests_served)} sub="all time" />
      <Stat
        label="Tokens"
        value={abbreviateNumber(provider.lifetime_tokens_generated)}
        sub="generated, all time"
      />
      <Stat label="Avg TTFT" value={ttft} sub={`up ${humanizeUptime(rep.total_uptime_seconds)}`} />
    </div>
  );
}
