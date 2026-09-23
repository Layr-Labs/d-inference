import { AppAttestReadiness } from "@/components/app-attest/Readiness";
import Link from "next/link";
import { DbError } from "@/components/DbError";
import { StatCard } from "@/components/StatCard";
import { isUndefinedTable } from "@/lib/db";
import { appAttestArchiveHealth, appAttestCensus, appAttestMachines, appAttestStages, observationDays } from "@/lib/queries/app-attest";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export default async function AppAttestPage({ searchParams }: { searchParams: Promise<{ days?: string }> }) {
  const days = observationDays((await searchParams).days);
  const [census, machines, stages, archive] = await Promise.allSettled([
    appAttestCensus(days), appAttestMachines(days), appAttestStages(days), appAttestArchiveHealth(days),
  ]);
  const unavailable = (reason: unknown) => isUndefinedTable(reason)
    ? <p className="text-amber-500">Awaiting the coordinator schema rollout. Data is unavailable.</p>
    : <DbError />;
  return <div className="space-y-6">
    <div><h1 className="text-lg font-semibold">App Attest · evidence and authorization</h1>
      <p className="mt-1 text-sm text-[var(--text-dim)]">Evidence collection and serving authorization are separate. MDM-free serving requires current coordinator authorization; a historical successful proof does not establish it.</p>
      <div className="mt-3 flex gap-4"><Link href="?days=1">Last 24 hours</Link><Link href="?days=7">Last 7 days</Link><span className="text-[var(--text-faint)]">Showing {days === 1 ? "24 hours" : "7 days"}</span></div>
    </div>
    {census.status === "fulfilled" ? <>
      <div className="grid gap-3 md:grid-cols-4">
        <StatCard label="Registered machine identities" value={census.value.machines} />
        <StatCard label="Distinct accounts" value={census.value.accounts} />
        <StatCard label="Connection sessions" value={census.value.sessions} />
        <StatCard label="Currently observed online" value={census.value.online} />
      </div>
      <p className="text-sm text-[var(--text-dim)]">
        Identity evidence: {census.value.hardware_verified} hardware verified, {census.value.key_bound} key bound, {census.value.provisional} provisional.
        Latest OS: {census.value.macos27} macOS 27+, {census.value.os_unknown} unknown.
        Ever observed on macOS 27+: {census.value.ever_macos27}.
        Protocol capable: {census.value.protocol_capable}; shadow disabled: {census.value.shadow_off}.
        Verified assertion machines: {census.value.verified_machines}; distinct verified credentials: {census.value.credentials}.
        Refused submissions: {census.value.refused}; imported historical sessions: {census.value.historical_sessions}.
      </p>
    </> : unavailable(census.reason)}
    <p className="text-sm text-[var(--text-dim)]">The denominator includes every registered identity seen in this window, including older clients and failures. Reconnects count as sessions. Key-bound and provisional identities are not proven unique physical Macs. OS values are app-reported; old records without OS data stay unknown. Historical backfill runs in bounded batches.</p>
    <p className="text-sm text-[var(--text-dim)]">Readiness is the latest recorded proof and authorization attempt. Current serving authorization can expire or be revoked afterward.</p>
    <AppAttestReadiness days={days} />
    <div className="space-y-2"><h2 className="font-semibold">Machine adoption</h2>
      <p className="text-sm text-[var(--text-dim)]">Latest 200 identities by last observation. “First 27+” is the first recorded observation, not the installation date. Fresh assertion means within the last 15 minutes.</p>
      {machines.status === "fulfilled" ? <div className="overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr><th>Machine / evidence</th><th>macOS / build</th><th>Provider / chip</th><th>Sessions</th><th>First 27+</th><th>Assertion</th></tr></thead><tbody>
        {machines.value.map(m => <tr key={m.machine_id} className="border-t border-[var(--border)]">
          <td className="py-3"><Link className="text-blue-400" href={`/app-attest/${m.machine_id}`}>{m.machine_id}</Link><div className="text-xs text-[var(--text-faint)]">{m.assurance}</div></td>
          <td>{m.os_version || "Unknown"}<div className="text-xs">{m.os_build || "Build unknown"}</div></td>
          <td>{m.version || "Unknown"}<div className="text-xs">{m.chip || "Unknown"}</div></td><td>{m.sessions}</td>
          <td>{m.first_macos27 ? new Date(m.first_macos27).toISOString() : "Not observed"}</td>
          <td className={m.last_assertion && new Date(m.evaluated_at).getTime()-new Date(m.last_assertion).getTime()<900_000 ? "text-emerald-500" : "text-amber-500"}>{m.last_assertion ? new Date(m.last_assertion).toISOString() : "None verified"}</td>
        </tr>)}
      </tbody></table></div> : unavailable(machines.reason)}
    </div>
    <div className="space-y-2"><h2 className="font-semibold">Compatibility, failures, and latency</h2>
      {stages.status === "fulfilled" ? <table className="w-full text-left text-sm"><thead><tr><th>Stage</th><th>Outcome</th><th>Unique machines</th><th>Events</th><th>p95 ms</th></tr></thead><tbody>{stages.value.map(r => <tr key={`${r.stage}:${r.outcome}`} className="border-t border-[var(--border)]"><td className="py-2">{r.stage}</td><td>{r.outcome}</td><td>{r.machines}</td><td>{r.events}</td><td>{r.p95_ms?.toFixed(1) ?? "—"}</td></tr>)}</tbody></table> : unavailable(stages.reason)}
    </div>
    <div className="space-y-2"><h2 className="font-semibold">Evidence and receipt archive</h2>
      <p className="text-sm text-[var(--text-dim)]">Proof bytes and results are stored durably in PostgreSQL. Pending rows await completion; interrupted verification is reconciled without changing credential counters. Write failures appear in the stage table and coordinator metrics. Receipt renewal needs dedicated server credentials; overdue jobs remain visible until configured.</p>
      {archive.status === "fulfilled" ? <table className="w-full text-left text-sm"><thead><tr><th>Record</th><th>Outcome</th><th>Count</th></tr></thead><tbody>{archive.value.map(r => <tr key={`${r.kind}:${r.outcome}`} className="border-t border-[var(--border)]"><td className="py-2">{r.kind}</td><td>{r.outcome}</td><td>{r.count}</td></tr>)}</tbody></table> : unavailable(archive.reason)}
    </div>
  </div>;
}
