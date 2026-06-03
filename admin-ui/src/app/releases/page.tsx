import { listReleases, countReleases, type ReleaseRow } from "@/lib/queries/releases";
import { DataTable, type Column } from "@/components/DataTable";
import { formatNumber, formatRelative, truncate } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const COLUMNS: Column<ReleaseRow>[] = [
  { key: "created_at", header: "Created", render: (r) => formatRelative(r.created_at) },
  { key: "version", header: "Version", mono: true, render: (r) => r.version || "—" },
  { key: "platform", header: "Platform", render: (r) => r.platform || "—" },
  { key: "backend", header: "Backend", render: (r) => r.backend || "—" },
  {
    key: "active",
    header: "Active",
    align: "right",
    render: (r) =>
      r.active ? (
        <span style={{ color: "var(--green)" }}>✓</span>
      ) : (
        <span className="text-[var(--text-faint)]">✗</span>
      ),
  },
  {
    key: "binary_hash",
    header: "Binary hash",
    mono: true,
    render: (r) => truncate(r.binary_hash, 10),
  },
  {
    key: "url",
    header: "URL",
    render: (r) =>
      r.url ? truncate(r.url, 40) : <span className="text-[var(--text-faint)]">—</span>,
  },
  {
    key: "changelog",
    header: "Changelog",
    render: (r) =>
      r.changelog ? truncate(r.changelog, 60) : <span className="text-[var(--text-faint)]">—</span>,
  },
];

export default async function ReleasesPage() {
  const [rows, total] = await Promise.all([listReleases(200), countReleases()]);
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">
        Releases <span className="text-[var(--text-faint)]">({formatNumber(total)})</span>
      </h1>
      <p className="text-sm text-[var(--text-dim)]">Provider binary releases, newest first.</p>
      <DataTable columns={COLUMNS} rows={rows} empty="No releases." />
    </div>
  );
}
