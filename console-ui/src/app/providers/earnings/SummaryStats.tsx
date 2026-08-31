"use client";

// Stacked lifetime stats column: total earned, jobs completed, avg per job.

import { formatAvgPerJob, formatMicroDollars } from "./format";

function StatRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="py-4 first:pt-0 last:pb-0">
      <p className="text-xs text-text-tertiary mb-1">{label}</p>
      <p className="text-2xl font-bold font-mono text-text-primary break-all">
        {value}
      </p>
    </div>
  );
}

export function SummaryStats({
  totalMicro,
  jobs,
}: {
  totalMicro: number;
  jobs: number;
}) {
  return (
    <div className="rounded-xl bg-bg-secondary shadow-sm p-5 divide-y divide-border-dim">
      <StatRow label="Total earned" value={formatMicroDollars(totalMicro)} />
      <StatRow label="Jobs completed" value={jobs.toLocaleString("en-US")} />
      <StatRow label="Avg per job" value={formatAvgPerJob(totalMicro, jobs)} />
    </div>
  );
}
