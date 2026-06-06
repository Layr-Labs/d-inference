import Link from "next/link";
import { getUptimeOverview, type SessionRow } from "@/lib/queries/sessions";
import { isUndefinedTable } from "@/lib/db";
import { DataTable, type Column } from "@/components/DataTable";
import { StatCard } from "@/components/StatCard";
import { formatNumber, formatRelative, formatDuration } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const COLUMNS: Column<SessionRow>[] = [
  {
    key: "status",
    header: "Status",
    render: (s) =>
      s.disconnected_at === null ? (
        <span style={{ color: "var(--green)" }}>● open</span>
      ) : (
        <span className="text-[var(--text-faint)]">ended</span>
      ),
  },
  {
    key: "serial_number",
    header: "Serial",
    mono: true,
    render: (s) =>
      s.serial_number ? (
        <Link
          href={`/providers/${s.serial_number}`}
          className="text-[var(--accent)] hover:underline"
        >
          {s.serial_number}
        </Link>
      ) : (
        <span className="text-[var(--text-faint)]">—</span>
      ),
  },
  {
    key: "email",
    header: "Owner",
    render: (s) => s.email || <span className="text-[var(--text-faint)]">unlinked</span>,
  },
  { key: "connected_at", header: "Connected", render: (s) => formatRelative(s.connected_at) },
  {
    key: "duration_seconds",
    header: "Duration",
    align: "right",
    render: (s) => formatDuration(s.duration_seconds),
  },
  { key: "last_seen", header: "Last seen", render: (s) => formatRelative(s.last_seen) },
  {
    key: "disconnect_reason",
    header: "Ended",
    render: (s) =>
      s.disconnected_at === null
        ? "—"
        : `${formatRelative(s.disconnected_at)} (${s.disconnect_reason || "?"})`,
  },
];

function NotDeployed() {
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">Uptime</h1>
      <div className="rounded-lg border border-[var(--border)] bg-[var(--bg-elevated)] p-4 text-sm text-[var(--text-dim)]">
        <div className="font-medium text-[var(--text)]">Uptime capture not deployed yet</div>
        <p className="mt-1">
          The <span className="mono">provider_sessions</span> table doesn&apos;t exist on the
          replica yet. It begins recording connect/disconnect history once the coordinator
          build with session capture is deployed.
        </p>
      </div>
    </div>
  );
}

export default async function UptimePage() {
  let data;
  let notDeployed = false;
  try {
    data = await getUptimeOverview(300);
  } catch (err) {
    if (!isUndefinedTable(err)) throw err;
    notDeployed = true;
  }
  if (notDeployed || !data) return <NotDeployed />;

  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">Uptime</h1>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
        <StatCard label="Open sessions" value={formatNumber(data.openSessions)} />
        <StatCard label="Sessions (24h)" value={formatNumber(data.sessions24h)} />
        <StatCard label="Total sessions" value={formatNumber(data.totalSessions)} />
      </div>
      <p className="text-sm text-[var(--text-dim)]">
        Connect→disconnect history per machine connection. &ldquo;Open&rdquo; = currently
        connected; duration is live for open sessions.
      </p>
      <DataTable columns={COLUMNS} rows={data.recent} empty="No sessions recorded yet." />
    </div>
  );
}
