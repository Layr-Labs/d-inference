import { getHeadlineStats, getTableCounts } from "@/lib/queries/overview";
import { DataTable, type Column } from "@/components/DataTable";
import { StatCard } from "@/components/StatCard";
import { formatNumber } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

interface CountRow {
  table: string;
  estRows: number;
}

const COUNT_COLUMNS: Column<CountRow>[] = [
  { key: "table", header: "Table", mono: true },
  {
    key: "estRows",
    header: "Est. rows",
    align: "right",
    render: (r) => formatNumber(r.estRows),
  },
];

export default async function OverviewPage() {
  const [stats, counts] = await Promise.all([getHeadlineStats(), getTableCounts()]);
  return (
    <div className="space-y-6">
      <h1 className="text-lg font-semibold">Overview</h1>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
        <StatCard label="Users" value={formatNumber(stats.users)} />
        <StatCard label="Machines" value={formatNumber(stats.machines)} />
        <StatCard
          label="Online now"
          value={`${formatNumber(stats.onlineMachines)} / ${formatNumber(stats.machines)}`}
        />
      </div>
      <div>
        <h2 className="mb-2 text-sm font-medium text-[var(--text-dim)]">Tables</h2>
        <DataTable columns={COUNT_COLUMNS} rows={counts} />
      </div>
    </div>
  );
}
