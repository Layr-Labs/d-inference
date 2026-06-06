import { listUsage, countUsage, type UsageRow } from "@/lib/queries/usage";
import { DataTable, type Column } from "@/components/DataTable";
import {
  formatNumber,
  formatUSDFromMicro,
  formatRelative,
  truncate,
} from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const COLUMNS: Column<UsageRow>[] = [
  { key: "created_at", header: "When", render: (r) => formatRelative(r.created_at) },
  { key: "model", header: "Model", render: (r) => r.model || "—" },
  {
    key: "prompt_tokens",
    header: "Prompt",
    align: "right",
    render: (r) => formatNumber(r.prompt_tokens),
  },
  {
    key: "completion_tokens",
    header: "Completion",
    align: "right",
    render: (r) => formatNumber(r.completion_tokens),
  },
  {
    key: "cost_micro_usd",
    header: "Cost",
    align: "right",
    render: (r) => formatUSDFromMicro(r.cost_micro_usd),
  },
  {
    key: "email",
    header: "Consumer",
    render: (r) => r.email || <span className="text-[var(--text-faint)]">unlinked</span>,
  },
  {
    key: "provider_id",
    header: "Provider",
    mono: true,
    render: (r) => truncate(r.provider_id),
  },
  {
    key: "request_id",
    header: "Request ID",
    mono: true,
    render: (r) => truncate(r.request_id),
  },
];

export default async function UsagePage() {
  const [rows, total] = await Promise.all([listUsage(200), countUsage()]);
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">
        Usage{" "}
        <span className="text-[var(--text-faint)]">({formatNumber(total)} total requests)</span>
      </h1>
      <p className="text-sm text-[var(--text-dim)]">Most recent 200, newest first.</p>
      <DataTable columns={COLUMNS} rows={rows} empty="No usage records." />
    </div>
  );
}
