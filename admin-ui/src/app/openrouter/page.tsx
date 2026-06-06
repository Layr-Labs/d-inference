import { listOpenRouterAccounts, type OpenRouterAccountRow } from "@/lib/queries/openrouter";
import { DataTable, type Column } from "@/components/DataTable";
import { StatCard } from "@/components/StatCard";
import { formatNumber, formatUSDFromMicro, formatRelative } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function RoleBadge({ role }: { role: string }) {
  if (role === "service") {
    return (
      <span
        className="rounded px-1.5 py-0.5 text-xs"
        style={{ background: "var(--bg-hover)", color: "var(--accent)" }}
      >
        service
      </span>
    );
  }
  return <span className="text-[var(--text-faint)]">member</span>;
}

const COLUMNS: Column<OpenRouterAccountRow>[] = [
  { key: "email", header: "Account", render: (a) => a.email || "—" },
  { key: "role", header: "Type", render: (a) => <RoleBadge role={a.role} /> },
  {
    key: "balance_micro_usd",
    header: "Balance",
    align: "right",
    render: (a) => formatUSDFromMicro(a.balance_micro_usd),
  },
  { key: "key_count", header: "API keys", align: "right", render: (a) => formatNumber(a.key_count) },
  {
    key: "usage_requests",
    header: "Requests",
    align: "right",
    render: (a) => formatNumber(a.usage_requests),
  },
  {
    key: "usage_cost_micro",
    header: "Usage cost",
    align: "right",
    render: (a) => formatUSDFromMicro(a.usage_cost_micro),
  },
  {
    key: "ledger_count",
    header: "Ledger rows",
    align: "right",
    render: (a) => formatNumber(a.ledger_count),
  },
  { key: "created_at", header: "Joined", render: (a) => formatRelative(a.created_at) },
  { key: "account_id", header: "Account ID", mono: true },
];

export default async function OpenRouterPage() {
  const rows = await listOpenRouterAccounts();
  const serviceCount = rows.filter((r) => r.role === "service").length;
  const totalBalance = rows.reduce((s, r) => s + Number(r.balance_micro_usd), 0);
  const totalCost = rows.reduce((s, r) => s + Number(r.usage_cost_micro), 0);

  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">OpenRouter</h1>
      <p className="text-sm text-[var(--text-dim)]">
        OpenRouter is integrated as <span className="mono">@openrouter.ai</span> accounts.
        The <span className="mono">service</span>-role channels get elevated rate limits and
        are billed at the platform price (no markup); Darkbloom also publishes an
        OpenRouter-compatible <span className="mono">/v1/models</span> feed. There is no
        dedicated OpenRouter table — this view aggregates accounts, keys, balances, ledger
        and usage.
      </p>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <StatCard label="Accounts" value={formatNumber(rows.length)} />
        <StatCard label="Service channels" value={formatNumber(serviceCount)} />
        <StatCard label="Total balance" value={formatUSDFromMicro(totalBalance)} />
        <StatCard label="Total usage cost" value={formatUSDFromMicro(totalCost)} />
      </div>
      <DataTable columns={COLUMNS} rows={rows} empty="No OpenRouter accounts found." />
    </div>
  );
}
