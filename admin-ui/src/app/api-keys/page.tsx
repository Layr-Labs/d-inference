import { listApiKeys, countApiKeys, type ApiKeyRow } from "@/lib/queries/apikeys";
import { DataTable, type Column } from "@/components/DataTable";
import { formatNumber, formatUSDFromMicro, formatRelative } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const COLUMNS: Column<ApiKeyRow>[] = [
  {
    key: "email",
    header: "Owner",
    render: (k) => k.email || <span className="text-[var(--text-faint)]">unlinked</span>,
  },
  { key: "name", header: "Name", render: (k) => k.name || "—" },
  { key: "raw_prefix", header: "Prefix", mono: true, render: (k) => k.raw_prefix || "—" },
  {
    key: "active",
    header: "Status",
    render: (k) =>
      k.active ? (
        <span style={{ color: "var(--green)" }}>active</span>
      ) : (
        <span className="text-[var(--text-faint)]">revoked</span>
      ),
  },
  {
    key: "limit_micro_usd",
    header: "Spend limit",
    align: "right",
    render: (k) => (k.limit_micro_usd == null ? "none" : formatUSDFromMicro(k.limit_micro_usd)),
  },
  {
    key: "rpm_limit",
    header: "RPM",
    align: "right",
    render: (k) => (k.rpm_limit == null ? "—" : formatNumber(k.rpm_limit)),
  },
  { key: "last_used_at", header: "Last used", render: (k) => formatRelative(k.last_used_at) },
  { key: "created_at", header: "Created", render: (k) => formatRelative(k.created_at) },
  { key: "id", header: "Key ID", mono: true, render: (k) => k.id || "—" },
];

export default async function ApiKeysPage() {
  const [rows, total] = await Promise.all([listApiKeys(200), countApiKeys()]);
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">
        API Keys <span className="text-[var(--text-faint)]">({formatNumber(total)})</span>
      </h1>
      <p className="text-sm text-[var(--text-dim)]">
        Most recent 200, newest first. Metadata only — key secrets are never stored or shown here.
      </p>
      <DataTable columns={COLUMNS} rows={rows} empty="No API keys." />
    </div>
  );
}
