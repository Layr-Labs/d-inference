// Lifetime earnings broken down per machine. Machines are identified by
// provider_key (stable X25519 hardware identity) and labeled with the
// hardware description from their provider record; every row also shows the
// tail of that key as a machine ID, so identical hardware stays
// distinguishable. Earnings rows with no provider_key (recorded before the
// crediting path populated it) aggregate into one "Other" bucket — they
// cannot be attributed retroactively, but the dollars must still appear.

export interface MachineEarnings {
  provider_key: string;
  chip_name?: string;
  memory_gb?: number;
  total_micro_usd: number;
  total_usd: string;
  job_count: number;
  prompt_tokens: number;
  completion_tokens: number;
  last_earned_at: string;
}

export function machineLabel(m: MachineEarnings): string {
  if (!m.provider_key) return "Other";
  if (m.chip_name) {
    return m.memory_gb ? `${m.chip_name} · ${m.memory_gb} GB` : m.chip_name;
  }
  return "Machine";
}

export function machineId(m: MachineEarnings): string {
  return m.provider_key ? `ID …${m.provider_key.slice(-6)}` : "";
}

export function ByMachineList({ machines }: { machines: MachineEarnings[] }) {
  if (!machines || machines.length === 0) return null;

  return (
    <div>
      <h3 className="text-sm font-semibold text-text-primary mb-3">Earnings by Machine</h3>
      <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
        <table className="w-full">
          <thead>
            <tr className="border-b border-border-dim">
              <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Machine</th>
              <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Earned</th>
              <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Jobs</th>
            </tr>
          </thead>
          <tbody>
            {machines.map((m) => (
              <tr key={m.provider_key || "other"} className="border-b border-border-dim/50 last:border-0">
                <td className="px-4 py-3 text-sm text-text-primary">
                  {machineLabel(m)}
                  <span className="block text-xs font-mono text-text-tertiary">
                    {m.provider_key ? machineId(m) : "earnings not attributed to a machine"}
                  </span>
                </td>
                <td className="px-4 py-3 text-sm font-mono text-accent-green">
                  ${m.total_usd}
                </td>
                <td className="px-4 py-3 text-sm text-text-tertiary">
                  {m.job_count.toLocaleString()}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
