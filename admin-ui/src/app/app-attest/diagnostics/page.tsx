import Link from "next/link";
import type { ReactNode } from "react";
import { DbError } from "@/components/DbError";
import { StatCard } from "@/components/StatCard";
import { isUndefinedTable } from "@/lib/db";
import { COHORTS, DEATH_CLASSES, groupBreakdown, pivotDeaths, type DimensionBreakdown } from "@/lib/app-attest-diagnostics";
import { observationDays } from "@/lib/queries/app-attest";
import {
  appAttestDiagnosticBreakdown, appAttestDiagnosticCohorts, appAttestDiagnosticCoverage,
  appAttestKeyDeathsByDay, appAttestPushReceipt, appAttestRecentKeyDeaths, appAttestRotationEvents, appAttestRotationOutcomes,
} from "@/lib/queries/app-attest-diagnostics";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const row = "border-t border-[var(--border)]";
const noData = <span className="text-[var(--text-faint)]">no data yet</span>;

function Section({ title, children, note }: { title: string; note?: string; children: ReactNode }) {
  return <section className="space-y-2"><h2 className="font-semibold">{title}</h2>
    {note && <p className="text-sm text-[var(--text-dim)]">{note}</p>}{children}</section>;
}

function Breakdown({ dims }: { dims: DimensionBreakdown[] }) {
  return <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">{dims.map(d =>
    <div key={d.dimension} className="rounded border border-[var(--border)] p-2 text-sm">
      <div className="mono text-xs text-[var(--text-dim)]">{d.dimension}</div>
      {d.noData ? noData : <table className="w-full text-left"><tbody>
        {d.values.map(v => <tr key={v.value} className={row}><td className="mono py-1 break-all">{v.value}</td>
          <td className="text-right tabular-nums">{v.machines} m</td><td className="text-right tabular-nums">{v.events} ev</td></tr>)}
      </tbody></table>}
      {d.missingEvents > 0 && <div className="text-xs text-[var(--text-faint)]">{d.missingEvents} events without this field</div>}
    </div>)}</div>;
}

export default async function AppAttestDiagnosticsPage({ searchParams }: { searchParams: Promise<{ days?: string }> }) {
  const days = observationDays((await searchParams).days);
  const [cohorts, coverage, breakdown, deathDays, deaths, rotations, rotationEvents, pushes] = await Promise.allSettled([
    appAttestDiagnosticCohorts(days), appAttestDiagnosticCoverage(days), appAttestDiagnosticBreakdown(days),
    appAttestKeyDeathsByDay(days), appAttestRecentKeyDeaths(days), appAttestRotationOutcomes(days), appAttestRotationEvents(days),
    appAttestPushReceipt(days),
  ]);
  const unavailable = (reason: unknown) => isUndefinedTable(reason)
    ? <p className="text-amber-500">Awaiting the coordinator schema rollout. Data is unavailable.</p>
    : <DbError />;
  const counts = cohorts.status === "fulfilled" ? cohorts.value : [];
  const grouped = breakdown.status === "fulfilled" ? groupBreakdown(breakdown.value) : null;
  return <div className="space-y-6">
    <div><Link href={`/app-attest?days=${days}`}>← App Attest rollout</Link>
      <h1 className="mt-2 text-lg font-semibold">App Attest · failure diagnostics</h1>
      <p className="mt-1 text-sm text-[var(--text-dim)]">Unexplained failure cohorts on machines whose connection reported macOS 27 or later. Diagnostic fields are untrusted client context, validated and bounded by the coordinator; they never affect authorization. Older clients do not send them, so missing values show as “no data yet”.</p>
      <div className="mt-3 flex gap-4"><Link href="?days=1">Last 24 hours</Link><Link href="?days=7">Last 7 days</Link><span className="text-[var(--text-faint)]">Showing {days === 1 ? "24 hours" : "7 days"}</span></div>
    </div>
    {coverage.status === "fulfilled" ? <div className="grid gap-3 md:grid-cols-3">
      <StatCard label="macOS 27+ machines seen" value={coverage.value.machines} />
      <StatCard label="Ready replies with new diagnostics" value={`${coverage.value.diagnosed_events} / ${coverage.value.ready_events}`} />
      <StatCard label="Machines sending new diagnostics" value={coverage.value.diagnosed_machines} />
    </div> : unavailable(coverage.reason)}
    <Section title="Unknown cohorts" note="Events and distinct machine identities per failure mode in the window.">
      {cohorts.status === "fulfilled" ? <table className="w-full text-left text-sm"><thead><tr><th>Cohort</th><th>Definition</th><th>Machines</th><th>Events</th></tr></thead><tbody>
        {COHORTS.map(c => { const n = counts.find(r => r.cohort === c.id); return <tr key={c.id} className={row}>
          <td className="mono py-2"><a className="text-blue-400" href={`#${c.id}`}>{c.id}</a></td><td className="text-[var(--text-dim)]">{c.detail}</td>
          <td className="tabular-nums">{n?.machines ?? "0"}</td><td className="tabular-nums">{n?.events ?? "0"}</td></tr>; })}
      </tbody></table> : unavailable(cohorts.reason)}
    </Section>
    {grouped ? COHORTS.map(c => <Section key={c.id} title={c.label} note={`Top 12 values per field; m = distinct machines, ev = events. Field values are from the failing event itself (ready-reply context is carried through its attempt).`}>
      <div id={c.id}>{counts.some(r => r.cohort === c.id) ? <Breakdown dims={grouped[c.id]} /> : noData}</div>
    </Section>) : breakdown.status === "rejected" && unavailable(breakdown.reason)}
    <Section title="Key deaths" note="First dead-key assertion per key in the window, compared with that key’s last verified assertion. os_change: OS build differs; reboot/process_restart: coordinator-derived flags, or boot_time/process_started_at differences on older rows; no_restart: neither changed; unknown: inputs missing.">
      {deathDays.status === "fulfilled" ? (deathDays.value.length === 0 ? noData : <table className="w-full text-left text-sm"><thead><tr><th>Day (UTC)</th>{DEATH_CLASSES.map(k => <th key={k}>{k}</th>)}<th>Previous exit clean / unclean</th><th>Machines</th></tr></thead><tbody>
        {pivotDeaths(deathDays.value).map(d => <tr key={d.day} className={row}><td className="py-2">{d.day}</td>
          {DEATH_CLASSES.map(k => <td key={k} className="tabular-nums">{d[k]}</td>)}<td className="tabular-nums">{d.clean} / {d.unclean}</td><td className="tabular-nums">{d.machines}</td></tr>)}
      </tbody></table>) : unavailable(deathDays.reason)}
      {deaths.status === "fulfilled" ? (deaths.value.length > 0 && <div className="overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr><th>Died</th><th>Machine</th><th>Class</th><th>OS build before → after</th><th>Last success</th><th>Previous exit / start / launch</th><th>Native error chain</th></tr></thead><tbody>
        {deaths.value.map(d => <tr key={d.key_id} className={row}><td className="py-2">{new Date(d.received_at).toISOString()}</td>
          <td><Link className="text-blue-400" href={`/app-attest/${d.machine_id}`}>{d.machine_id}</Link></td><td>{d.classification}</td>
          <td>{d.os_build_before ?? "?"} → {d.os_build_after ?? "?"}</td><td>{d.last_success_at ? new Date(d.last_success_at).toISOString() : "never"}</td>
          <td>{d.previous_exit ?? "—"} / {d.start_reason ?? "—"} / {d.launch_session ?? "—"}</td><td className="mono">{d.native_error_chain ?? "—"}</td></tr>)}
      </tbody></table></div>) : unavailable(deaths.reason)}
    </Section>
    <Section title="Key rotation" note="Durable rotation requests and whether a different key for the same account and scope (machine, or account fallback) later attested and verified an assertion within 7 days. Decisions come from coordinator rotation events.">
      {rotations.status === "fulfilled" ? (rotations.value.length === 0 ? noData : <table className="w-full text-left text-sm"><thead><tr><th>Reason</th><th>Requested</th><th>Scopes</th><th>Replacement attested</th><th>Replacement verified</th><th>Median to verified</th></tr></thead><tbody>
        {rotations.value.map(r => <tr key={r.reason} className={row}><td className="py-2">{r.reason}</td><td>{r.requested}</td><td>{r.scopes}</td><td>{r.replacement_attested}</td><td>{r.replacement_verified}</td>
          <td>{r.median_seconds_to_verified == null ? "—" : `${Math.round(r.median_seconds_to_verified)} s`}</td></tr>)}
      </tbody></table>) : unavailable(rotations.reason)}
      {rotationEvents.status === "fulfilled" ? (rotationEvents.value.length > 0 && <table className="w-full text-left text-sm"><thead><tr><th>Stage</th><th>Decision</th><th>Machines</th><th>Events</th></tr></thead><tbody>
        {rotationEvents.value.map(r => <tr key={`${r.stage}:${r.outcome}`} className={row}><td className="py-2">{r.stage}</td><td>{r.outcome}</td><td>{r.machines}</td><td>{r.events}</td></tr>)}
      </tbody></table>) : unavailable(rotationEvents.reason)}
    </Section>
    <Section title="APNs push receipt" note="All OS versions (legacy macOS < 27 waits on code-identity pushes). Latest ready snapshot per machine in the window. Token presence and 24-hour counts describe that snapshot, not current state. Ages advance to now for the last observed push; later activity is unknown. “Unanswered” means no reply was recorded after that push at snapshot time. Machines on older clients count as no data.">
      {pushes.status === "fulfilled" ? (pushes.value.length === 0 ? noData : <div className="overflow-x-auto"><table className="w-full text-left text-sm"><thead>
        <tr><th rowSpan={2}>OS</th><th rowSpan={2}>Machines</th><th colSpan={3}>Snapshot age</th><th colSpan={3}>Token at snapshot</th><th colSpan={5}>Pushes in 24 h before snapshot</th><th colSpan={4}>Last observed push age now</th><th rowSpan={2}>Unanswered at snapshot</th></tr>
        <tr>{["<1 h", "1–24 h", ">24 h", "true", "false", "no data", "0", "1–3", "4–10", ">10", "no data", "<1 h", "1–24 h", ">24 h", "never / no data"].map((h, i) => <th key={i} className="font-normal text-[var(--text-dim)]">{h}</th>)}</tr>
      </thead><tbody>{pushes.value.map(r => <tr key={r.os_group} className={row}><td className="py-2">{r.os_group}</td>
        {[r.machines, r.snapshot_under_1h, r.snapshot_1_24h, r.snapshot_over_24h, r.token_true, r.token_false, r.token_no_data, r.pushes_0, r.pushes_1_3, r.pushes_4_10, r.pushes_over_10, r.pushes_no_data,
          r.age_under_1h, r.age_1_24h, r.age_over_24h, r.age_never_or_no_data, r.last_push_unanswered].map((v, i) => <td key={i} className="tabular-nums">{v}</td>)}</tr>)}
      </tbody></table></div>) : unavailable(pushes.reason)}
    </Section>
    <p className="text-xs text-[var(--text-faint)]">Coordinator-side APNs send results and reply arrival are metrics only: <span className="mono">code_attest.push{"{outcome}"}</span> and <span className="mono">code_attest.push_reply{"{result}"}</span>.</p>
  </div>;
}
