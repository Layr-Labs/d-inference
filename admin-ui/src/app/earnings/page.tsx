import {
  listTopEarners,
  listRecentEarnings,
  type TopEarnerRow,
  type RecentEarningRow,
} from "@/lib/queries/earnings";
import { DataTable, type Column } from "@/components/DataTable";
import { formatNumber, formatUSDFromMicro, formatRelative, truncate } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const TOP_COLUMNS: Column<TopEarnerRow>[] = [
  {
    key: "email",
    header: "Account",
    render: (e) => e.email || <span className="text-[var(--text-faint)]">unlinked</span>,
  },
  {
    key: "total_micro_usd",
    header: "Lifetime earned",
    align: "right",
    render: (e) => formatUSDFromMicro(e.total_micro_usd),
  },
  {
    key: "total_count",
    header: "Jobs",
    align: "right",
    render: (e) => formatNumber(e.total_count),
  },
  {
    key: "tokens",
    header: "Tokens",
    align: "right",
    render: (e) =>
      formatNumber(
        Number(e.total_prompt_tokens || 0) + Number(e.total_completion_tokens || 0),
      ),
  },
  { key: "key", header: "Account ID", mono: true },
];

const RECENT_COLUMNS: Column<RecentEarningRow>[] = [
  { key: "created_at", header: "When", render: (r) => formatRelative(r.created_at) },
  {
    key: "email",
    header: "Account",
    render: (r) => r.email || <span className="text-[var(--text-faint)]">unlinked</span>,
  },
  { key: "model", header: "Model", render: (r) => r.model || "—" },
  {
    key: "amount_micro_usd",
    header: "Amount",
    align: "right",
    render: (r) => formatUSDFromMicro(r.amount_micro_usd),
  },
  {
    key: "provider_id",
    header: "Provider",
    mono: true,
    render: (r) => truncate(r.provider_id, 16),
  },
  { key: "job_id", header: "Job", mono: true, render: (r) => truncate(r.job_id, 16) },
];

export default async function EarningsPage() {
  const [topEarners, recent] = await Promise.all([
    listTopEarners(100),
    listRecentEarnings(100),
  ]);
  return (
    <div className="space-y-8">
      <div className="space-y-4">
        <h1 className="text-lg font-semibold">
          Top earners{" "}
          <span className="text-[var(--text-faint)]">({formatNumber(topEarners.length)})</span>
        </h1>
        <p className="text-sm text-[var(--text-dim)]">
          Lifetime totals per account, from the materialized{" "}
          <span className="mono">earnings_summary</span> table. Top 100 by lifetime earnings.
        </p>
        <DataTable columns={TOP_COLUMNS} rows={topEarners} empty="No earnings yet." />
      </div>

      <div className="space-y-4">
        <h2 className="text-lg font-semibold">Recent earnings</h2>
        <p className="text-sm text-[var(--text-dim)]">
          Most recent 100 per-job credits, newest first.
        </p>
        <DataTable columns={RECENT_COLUMNS} rows={recent} empty="No recent earnings." />
      </div>
    </div>
  );
}
