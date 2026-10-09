// Live vitals cluster — thermal, memory pressure, CPU, concurrency, plus a
// throughput line and GPU memory bar. Hand-built gauges, every gauge paired
// with a mono number. Guarded at the boundary: an offline machine with no live
// snapshot shows an honest line, never a wall of misleading zeros.

import type { MyProvider } from "../types";
import { clampPct, formatTps, pct } from "./format";
import { MeterBar, StackedBar, pressureColor, cpuColor } from "./gauges/MeterBar";
import { ThermalPips } from "./gauges/ThermalPips";
import { ConcurrencyDots } from "./gauges/ConcurrencyDots";

function Vital({
  label,
  value,
  children,
}: {
  label: string;
  value: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-1.5">
      <div className="flex items-center justify-between gap-2">
        <span className="text-[10px] uppercase tracking-wider text-text-tertiary">{label}</span>
        <span className="text-xs font-mono font-semibold text-text-primary capitalize tabular-nums">{value}</span>
      </div>
      {children}
    </div>
  );
}

export function CardVitals({
  provider,
  fleetMaxDecodeTps,
}: {
  provider: MyProvider;
  fleetMaxDecodeTps: number;
}) {
  const sm = provider.system_metrics;
  const cap = provider.backend_capacity;

  if (!sm && !cap) {
    const msg =
      provider.status === "never_seen"
        ? "Live metrics resume when this machine first connects."
        : "No live metrics — machine offline.";
    return <p className="px-4 py-3 text-xs text-text-tertiary">{msg}</p>;
  }

  const decode = provider.decode_tps ?? 0;
  const prefill = provider.prefill_tps ?? 0;
  const decodePct = fleetMaxDecodeTps > 0 ? (decode / fleetMaxDecodeTps) * 100 : 0;

  return (
    <div className="px-4 py-3 space-y-3">
      {sm && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-x-4 gap-y-3">
          <Vital label="Thermal" value={sm.thermal_state}>
            <ThermalPips state={sm.thermal_state} />
          </Vital>
          <Vital label="Memory" value={pct(sm.memory_pressure)}>
            <MeterBar
              value={sm.memory_pressure * 100}
              colorClass={pressureColor(sm.memory_pressure)}
              label={`Memory pressure ${pct(sm.memory_pressure)}`}
            />
          </Vital>
          <Vital label="CPU" value={pct(sm.cpu_usage)}>
            <MeterBar
              value={sm.cpu_usage * 100}
              colorClass={cpuColor(sm.cpu_usage)}
              label={`CPU usage ${pct(sm.cpu_usage)}`}
            />
          </Vital>
          <Vital label="Concurrency" value={`${provider.pending_requests}/${provider.max_concurrency || 0}`}>
            <div className="h-2 flex items-center">
              <ConcurrencyDots pending={provider.pending_requests} max={provider.max_concurrency} />
            </div>
          </Vital>
        </div>
      )}

      {/* Throughput — decode drives scoring, so it leads and gets the bar. */}
      <div className="flex items-center gap-3">
        <span className="text-[10px] uppercase tracking-wider text-text-tertiary shrink-0">Decode</span>
        <div className="flex-1 min-w-0">
          <MeterBar
            value={decodePct}
            colorClass="bg-accent-brand"
            height="h-1"
            label={`Decode ${formatTps(decode)} tokens per second`}
          />
        </div>
        <span className="text-xs font-mono text-text-primary shrink-0">
          {formatTps(decode)}
          <span className="text-text-tertiary"> tok/s</span>
        </span>
        {prefill > 0 && (
          <span className="text-[11px] font-mono text-text-tertiary shrink-0 hidden sm:inline">
            prefill {formatTps(prefill)}
          </span>
        )}
      </div>

      {cap && cap.total_memory_gb > 0 && (
        <div className="space-y-1.5">
          <div className="flex items-center justify-between">
            <span className="text-[10px] uppercase tracking-wider text-text-tertiary">GPU memory</span>
            <span className="text-[11px] font-mono text-text-secondary">
              {cap.gpu_memory_active_gb.toFixed(1)} active · {cap.gpu_memory_cache_gb.toFixed(1)} cache ·{" "}
              {cap.total_memory_gb.toFixed(0)} GB
            </span>
          </div>
          <StackedBar
            label="GPU memory usage"
            segments={[
              { value: clampPct((cap.gpu_memory_active_gb / cap.total_memory_gb) * 100), colorClass: "bg-accent-brand" },
              { value: clampPct((cap.gpu_memory_cache_gb / cap.total_memory_gb) * 100), colorClass: "bg-accent-brand/40" },
            ]}
          />
        </div>
      )}
    </div>
  );
}
