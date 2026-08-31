"use client";

// Lifetime KPI cards row: total earned, jobs completed, avg per job.

import type { ReactNode } from "react";
import { Briefcase, DollarSign, TrendingUp } from "lucide-react";
import { formatAvgPerJob, formatMicroDollars } from "./format";

function StatCard({
  icon,
  label,
  value,
}: {
  icon: ReactNode;
  label: string;
  value: string;
}) {
  return (
    <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
      <div className="flex items-center gap-2 mb-2">
        {icon}
        <p className="text-xs text-text-tertiary">{label}</p>
      </div>
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
    <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
      <StatCard
        icon={<DollarSign size={16} className="text-accent-green" />}
        label="Total earned"
        value={formatMicroDollars(totalMicro)}
      />
      <StatCard
        icon={<Briefcase size={16} className="text-accent-amber" />}
        label="Jobs completed"
        value={jobs.toLocaleString("en-US")}
      />
      <StatCard
        icon={<TrendingUp size={16} className="text-accent-brand" />}
        label="Avg per job"
        value={formatAvgPerJob(totalMicro, jobs)}
      />
    </div>
  );
}
