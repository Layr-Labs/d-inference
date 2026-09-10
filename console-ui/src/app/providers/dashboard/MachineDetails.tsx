import type { MyProvider } from "../types";
import { formatRelative, humanizeUptime } from "./format";

const UNREPORTED = "Not reported";

export function MachineDetails({ provider }: { provider: MyProvider }) {
  const { hardware } = provider;
  const cpu = hardware.cpu_cores;
  const details = [
    ["Machine ID", provider.id],
    ["Model identifier", hardware.machine_model || UNREPORTED],
    ["Provider version", provider.version ? `v${provider.version}` : UNREPORTED],
    ["CPU cores", cpu ? `${cpu.performance ?? "—"} performance · ${cpu.efficiency ?? "—"} efficiency` : UNREPORTED],
    ["Memory bandwidth", hardware.memory_bandwidth_gbs ? `${hardware.memory_bandwidth_gbs} GB/s` : UNREPORTED],
    ["Total uptime", humanizeUptime(provider.reputation.total_uptime_seconds)],
    [provider.online ? "Last heartbeat" : "Last seen", formatRelative(provider.last_heartbeat || provider.last_seen)],
    ["Linked", formatRelative(provider.registered_at)],
  ];
  return (
    <dl className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs">
      {details.map(([label, value]) => (
        <div key={label} className="min-w-0">
          <dt className="text-text-tertiary">{label}</dt>
          <dd className="mt-1 break-all font-mono text-text-secondary">{value}</dd>
        </div>
      ))}
    </dl>
  );
}
