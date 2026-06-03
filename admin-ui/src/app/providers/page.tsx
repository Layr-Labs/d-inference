import { listMachines, countMachines } from "@/lib/queries/providers";
import { MachinesView } from "./MachinesView";
import { formatNumber, isOnline } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Load the whole fleet (~1.1k machines) so client-side filter/sort/copy span all
// of them. If the fleet ever grows past a few thousand, move to server-side
// pagination/filtering.
const MACHINE_LIMIT = 5000;

export default async function MachinesPage() {
  const [rows, total] = await Promise.all([listMachines(MACHINE_LIMIT), countMachines()]);
  const online = rows.filter((m) => isOnline(m.last_seen)).length;
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">
        Machines <span className="text-[var(--text-faint)]">({formatNumber(total)})</span>
      </h1>
      <p className="text-sm text-[var(--text-dim)]">
        Deduplicated by serial (latest session) — all {formatNumber(rows.length)} shown,{" "}
        {formatNumber(online)} online. Filter, sort, and copy owner emails. Uptime/downtime
        history isn&apos;t persisted yet — &ldquo;online&rdquo; is{" "}
        <span className="mono">last_seen</span> within 90s.
      </p>
      <MachinesView rows={rows} />
    </div>
  );
}
