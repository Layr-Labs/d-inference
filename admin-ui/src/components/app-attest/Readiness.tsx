import { DbError } from "@/components/DbError";
import { appAttestReadinessCohorts, appAttestReadinessReasons } from "@/lib/queries/app-attest-readiness";

export async function AppAttestReadiness({ days }: { days: number }) {
  const [cohorts, reasons] = await Promise.allSettled([appAttestReadinessCohorts(days), appAttestReadinessReasons(days)]);
  if (cohorts.status !== "fulfilled" || reasons.status !== "fulfilled") return <DbError />;
  const online = cohorts.value.filter(c => c.readiness !== "offline").reduce((n, c) => n + Number(c.machines), 0);
  const eligible = cohorts.value.filter(c => c.readiness === "eligible").reduce((n, c) => n + Number(c.machines), 0);
  return <section className="space-y-3">
    <h2 className="font-semibold">Readiness for MDM retirement</h2>
    <p className="text-sm text-[var(--text-dim)]"><strong>{eligible} / {online}</strong> observed online machine identities have an unexpired eligible prospective verdict on their latest connection. No verdict changes serving or payouts.</p>
    <p className="text-sm text-[var(--text-dim)]">All identities seen in the selected window are included below. Offline machines are shown separately; older clients, excluded rollout cohorts, missing evidence and stale checks cannot count as eligible. Build qualification, macOS security-transition tests, supported-OS policy and accounting migration must be completed before retirement.</p>
    <table className="w-full text-left text-sm"><thead><tr><th>Readiness</th><th>Provider version</th><th>Machine identities</th></tr></thead><tbody>
      {cohorts.value.map(c => <tr key={`${c.readiness}:${c.version}`} className="border-t border-[var(--border)]"><td className={`py-2 ${c.readiness === "eligible" ? "text-emerald-500" : "text-amber-500"}`}>{c.readiness}</td><td>{c.version}</td><td>{c.machines}</td></tr>)}
    </tbody></table>
    <table className="w-full text-left text-sm"><thead><tr><th>Missing or rejected condition</th><th>Machine identities</th></tr></thead><tbody>
      {reasons.value.map(r => <tr key={r.reason} className="border-t border-[var(--border)]"><td className="py-2">{r.reason}</td><td>{r.machines}</td></tr>)}
    </tbody></table>
    <p className="text-xs text-[var(--text-faint)]">These are recent evaluations, not live authorization leases. Catalog/configuration changes require another evaluation. Revocations and expiry are checked by this view; multiple reasons can apply to one machine.</p>
  </section>;
}
