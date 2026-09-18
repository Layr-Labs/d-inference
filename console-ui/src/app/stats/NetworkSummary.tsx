import { Cpu, Activity, ShieldCheck, Server } from "lucide-react";
import { activeNetworkPowerWatts } from "@/lib/network-power";
import { formatPower } from "@/lib/format-power";
import { formatBandwidth, formatCompactNumber } from "./format";
import type { PlatformStats } from "./platform-types";
import type { NetworkWindowTotals } from "./types";

export function NetworkSummary({ stats, totals24h }: { stats: PlatformStats; totals24h: NetworkWindowTotals | null }) {
  const hardware = stats.providers.filter((provider) => provider.trust_level === "hardware").length;
  const requests = stats.last_24h_requests ?? totals24h?.jobs;
  const tokens = stats.last_24h_total_tokens ?? totals24h?.tokens;
  const metrics = [
    { label: "Macs online", value: stats.active_providers.toLocaleString(), detail: "Connected Apple Silicon providers", icon: Cpu },
    { label: "Hardware verified", value: hardware.toLocaleString(), detail: "Providers with hardware attestation", icon: ShieldCheck },
    { label: "Requests · 24 hours", value: requests === undefined ? "—" : formatCompactNumber(requests), detail: `${formatCompactNumber(stats.total_requests)} since launch`, icon: Activity },
    { label: "Tokens · 24 hours", value: tokens === undefined ? "—" : formatCompactNumber(tokens), detail: `${formatCompactNumber(stats.total_tokens)} since launch`, icon: Server },
  ];
  return (
    <section aria-label="Network summary" className="grid grid-cols-2 gap-x-5 gap-y-7 py-7 lg:grid-cols-4 lg:gap-0">
      {metrics.map(({ label, value, detail, icon: Icon }) => <div key={label} className="min-w-0 lg:border-l lg:border-border-dim lg:px-7 lg:first:border-l-0 lg:first:pl-0 lg:last:pr-0"><p className="mb-3 flex items-center gap-2 text-xs text-text-secondary"><Icon size={14} strokeWidth={1.6} />{label}</p><p className="text-[36px] font-medium leading-none tracking-[-0.045em] text-text-primary tabular-nums sm:text-[42px]">{value}</p><p className="mt-2.5 text-[11px] leading-relaxed text-text-tertiary">{detail}</p></div>)}
    </section>
  );
}

export function NetworkResources({ stats }: { stats: PlatformStats }) {
  const watts = activeNetworkPowerWatts(stats);
  const utilization = stats.network_utilization?.utilization;
  const resources = [
    ["Unified memory", stats.total_memory_gb >= 1000 ? `${(stats.total_memory_gb / 1000).toFixed(1)} TB` : `${stats.total_memory_gb.toLocaleString()} GB`],
    ["Memory bandwidth", formatBandwidth(stats.total_bandwidth_gbs)],
    ["GPU cores", stats.total_gpu_cores.toLocaleString()],
    ["Estimated power", watts > 0 ? formatPower(watts) : "—"],
    ["CPU cores", stats.total_cpu_cores.toLocaleString()],
    ["Input tokens, all time", formatCompactNumber(stats.total_prompt_tokens)],
    ["Output tokens, all time", formatCompactNumber(stats.total_completion_tokens)],
    ["Mean tokens per request", Math.round(stats.avg_tokens_per_request).toLocaleString()],
    ["Reported token capacity", `${formatCompactNumber(stats.network_capacity_tps)} tok/s`],
    ["Reported utilization", typeof utilization === "number" ? `${Math.round(utilization * 100)}%` : "—"],
  ];
  return (
    <details className="border-t border-border-dim py-5">
      <summary className="cursor-pointer rounded text-sm font-medium text-text-primary">Hardware and lifetime totals</summary>
      <p className="mt-4 text-xs text-text-tertiary">Aggregated across connected providers. Token totals cover the network&apos;s lifetime.</p>
      <dl className="my-5 grid grid-cols-2 gap-6 md:grid-cols-4">
        {resources.map(([label, value]) => <div key={label}><dt className="text-xs text-text-secondary">{label}</dt><dd className="mt-2 text-lg font-medium tabular-nums text-text-primary">{value}</dd></div>)}
      </dl>
    </details>
  );
}
