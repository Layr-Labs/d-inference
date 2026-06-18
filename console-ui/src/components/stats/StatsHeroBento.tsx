"use client";

import { statsMetricLabel, statsMetricSub, statsMetricValue, statsReveal2 } from "./styles";

interface StatsHeroBentoProps {
  totalTokens: string;
  tokenSub: string;
  totalRequests: string;
  nodesOnline: string;
  nodesSub: string;
  bandwidth: string;
}

const bentoCard =
  "group relative overflow-hidden rounded-[0.35rem] border border-border-dim bg-bg-primary p-5 shadow-sm transition-[border-color,transform,box-shadow] hover:-translate-y-0.5 hover:border-accent-brand/30 hover:shadow-md";

export function StatsHeroBento({
  totalTokens,
  tokenSub,
  totalRequests,
  nodesOnline,
  nodesSub,
  bandwidth,
}: StatsHeroBentoProps) {
  return (
    <div className={`grid grid-cols-1 gap-2.5 md:grid-cols-[1.45fr_1fr_1fr] md:grid-rows-[auto_auto] ${statsReveal2}`}>
      <div
        className={`${bentoCard} md:col-start-1 md:row-span-2 flex min-h-48 flex-col justify-end bg-linear-to-br from-accent-brand-dim via-transparent to-bg-secondary`}
      >
        <span
          className="pointer-events-none absolute -top-6 -right-6 size-36 rounded-full border border-accent-brand/20"
          aria-hidden="true"
        />
        <span className="absolute top-3.5 right-4 font-mono text-[0.58rem] tracking-widest text-text-tertiary opacity-70" aria-hidden="true">
          01
        </span>
        <span className="pointer-events-none absolute top-2.5 left-2.5 size-3.5 border-t-2 border-l-2 border-accent-brand/45" aria-hidden="true" />
        <span className="pointer-events-none absolute right-2.5 bottom-2.5 size-3.5 border-r-2 border-b-2 border-accent-brand/45" aria-hidden="true" />
        <p className={statsMetricLabel}>Tokens served</p>
        <p className={`${statsMetricValue} text-[clamp(2.75rem,8vw,5rem)] bg-linear-to-b from-text-primary to-accent-brand bg-clip-text text-transparent`}>
          {totalTokens}
        </p>
        <p className={`${statsMetricSub} text-accent-green`}>{tokenSub}</p>
      </div>

      <div className={`${bentoCard} md:col-span-2 md:col-start-2 md:row-start-1`}>
        <span className="absolute top-3.5 right-4 font-mono text-[0.58rem] tracking-widest text-text-tertiary opacity-70" aria-hidden="true">
          02
        </span>
        <p className={statsMetricLabel}>Requests</p>
        <p className={`${statsMetricValue} text-[clamp(1.85rem,4.5vw,3rem)]`}>{totalRequests}</p>
        <p className={statsMetricSub}>lifetime completions</p>
      </div>

      <div className={bentoCard}>
        <span className="absolute top-3.5 right-4 font-mono text-[0.58rem] tracking-widest text-text-tertiary opacity-70" aria-hidden="true">
          03
        </span>
        <p className={statsMetricLabel}>Nodes online</p>
        <p className={`${statsMetricValue} text-[clamp(1.4rem,3vw,2.1rem)]`}>{nodesOnline}</p>
        <p className={statsMetricSub}>{nodesSub}</p>
      </div>

      <div className={bentoCard}>
        <span className="absolute top-3.5 right-4 font-mono text-[0.58rem] tracking-widest text-text-tertiary opacity-70" aria-hidden="true">
          04
        </span>
        <p className={statsMetricLabel}>GB/s bandwidth</p>
        <p className={`${statsMetricValue} text-[clamp(1.4rem,3vw,2.1rem)]`}>{bandwidth}</p>
        <p className={statsMetricSub}>unified memory throughput</p>
      </div>
    </div>
  );
}
