import { listOperators } from "@/lib/queries/operators";
import { OperatorsView } from "./OperatorsView";
import { StatCard } from "@/components/StatCard";
import { formatNumber } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export default async function OperatorsPage() {
  const rows = await listOperators();
  const totalMachines = rows.reduce((s, o) => s + o.machines, 0);
  const onlineMachines = rows.reduce((s, o) => s + o.online, 0);
  const multiMachine = rows.filter((o) => o.machines > 1).length;

  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">
        Operators <span className="text-[var(--text-faint)]">({formatNumber(rows.length)})</span>
      </h1>
      <p className="text-sm text-[var(--text-dim)]">
        Owners with at least one linked machine, machines aggregated per account. Filter, sort,
        and copy operator emails. Per-machine detail (serial, trust, status) lives on the{" "}
        <span className="mono">Machines</span> page; unlinked machines have no operator and
        aren&apos;t shown here.
      </p>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <StatCard label="Operators" value={formatNumber(rows.length)} />
        <StatCard label="Multi-machine" value={formatNumber(multiMachine)} />
        <StatCard label="Linked machines" value={formatNumber(totalMachines)} />
        <StatCard label="Online now" value={formatNumber(onlineMachines)} />
      </div>
      <OperatorsView rows={rows} />
    </div>
  );
}
