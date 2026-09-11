import { Activity, Boxes, MemoryStick, ArrowUpRight } from "lucide-react";
import type { MyProvider } from "../types";
import { fleetActivity } from "./activity";
import { abbreviateNumber, formatNumber } from "./format";

export function FleetActivity({ providers }: { providers: MyProvider[] }) {
  const stats = fleetActivity(providers);
  const queue = stats.queueReported === stats.online ? `${stats.queued} queued` : "queue partially reported";
  const serving = `${stats.serving} machine${stats.serving === 1 ? "" : "s"} serving`;
  const metrics = [
    { label: "Active requests", value: formatNumber(stats.requests), icon: Activity,
      detail: `${serving} · ${queue}` },
    { label: "Loaded models", value: formatNumber(stats.loadedModels), icon: Boxes,
      detail: `${stats.loadedCopies} reported copies across online Macs` },
    { label: "Online memory", value: stats.memoryReported ? `${formatNumber(stats.memoryGB)} GB` : "—", icon: MemoryStick,
      detail: `Physical RAM · ${stats.memoryReported}/${stats.online} Macs reporting` },
    { label: "Requests served", value: abbreviateNumber(stats.lifetimeRequests), icon: ArrowUpRight,
      detail: `${abbreviateNumber(stats.lifetimeTokens)} tokens · linked machines, all time` },
  ];
  return (
    <dl aria-label="Fleet activity" className="grid grid-cols-2 xl:grid-cols-4 gap-3">
      {metrics.map(({ label, value, detail, icon: Icon }) => (
        <div key={label} className="min-w-0 rounded-xl border border-border-dim bg-bg-secondary p-4">
          <dt className="flex items-center gap-2 text-xs text-text-secondary"><Icon size={14} className="text-accent-brand" />{label}</dt>
          <dd className="mt-3 text-xl sm:text-2xl font-mono font-semibold tabular-nums text-text-primary">{value}</dd>
          <dd className="mt-1 text-[11px] leading-relaxed text-text-tertiary">{detail}</dd>
        </div>
      ))}
    </dl>
  );
}
