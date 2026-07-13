import { TrendingUp } from "lucide-react";
import { formatBandwidth, formatCompactNumber } from "./format";
import type { NetworkWindowTotals } from "./types";

interface HeadlineMetricProps {
  value: string;
  label: string;
  detail?: string;
  change?: string;
}
function HeadlineMetric({ value, label, detail, change }: HeadlineMetricProps) {
  return (
    <div className="min-w-0 border-border-dim py-1 text-left even:border-l even:pl-5 xl:border-l xl:first:border-l-0 xl:pl-6 xl:first:pl-0">
      <p className="whitespace-nowrap font-mono text-3xl font-bold leading-none tracking-tighter text-text-primary tabular-nums xl:text-4xl">
        {value}
      </p>
      <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.16em] text-text-tertiary">
        {label}
      </p>
      {change && (
        <p className="mt-1.5 flex items-center gap-1 font-mono text-[11px] font-medium text-accent-green">
          <TrendingUp size={11} aria-hidden="true" />
          {change}
        </p>
      )}
      {detail && (
        <p className="mt-1 text-[11px] leading-4 text-text-tertiary">{detail}</p>
      )}
    </div>
  );
}

export function HeadlineMetrics({
  totalTokens,
  promptTokens,
  completionTokens,
  totalRequests,
  activeProviders,
  hardwareAttested,
  totalBandwidthGBs,
  last24h,
}: {
  totalTokens: number;
  promptTokens: number;
  completionTokens: number;
  totalRequests: number;
  activeProviders: number;
  hardwareAttested: number;
  totalBandwidthGBs: number;
  last24h: NetworkWindowTotals | null;
}) {
  return (
    <section className="rounded-2xl bg-bg-white px-5 py-6 shadow-sm sm:px-7">
      <div className="grid grid-cols-2 gap-x-5 gap-y-7 xl:grid-cols-4 xl:gap-x-0">
        <HeadlineMetric
          value={formatCompactNumber(totalTokens)}
          label="Tokens served"
          change={last24h ? `+${formatCompactNumber(last24h.tokens)} in 24h` : undefined}
          detail={`${formatCompactNumber(promptTokens)} in · ${formatCompactNumber(completionTokens)} out`}
        />
        <HeadlineMetric
          value={formatCompactNumber(totalRequests)}
          label="Requests"
          change={last24h ? `+${formatCompactNumber(last24h.jobs)} in 24h` : undefined}
        />
        <HeadlineMetric
          value={activeProviders.toLocaleString()}
          label="Nodes online"
          detail={
            hardwareAttested === activeProviders
              ? "All hardware-attested"
              : `${hardwareAttested.toLocaleString()} hardware-attested`
          }
        />
        <HeadlineMetric
          value={formatBandwidth(totalBandwidthGBs)}
          label="Memory bandwidth"
          detail="Combined provider throughput"
        />
      </div>
    </section>
  );
}
