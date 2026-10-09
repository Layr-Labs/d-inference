// Backend detail (inside the "Backend slots" accordion): GPU memory mini-stats
// plus a per-model slot table. The token-budget bar (active / max potential) is
// the literal headroom the coordinator admits new requests against.

import type { MyBackendCapacity } from "../types";
import { abbreviateNumber, clampPct, shortModelName } from "./format";
import { MeterBar } from "./gauges/MeterBar";

const STATE_TAG: Record<string, string> = {
  running: "bg-accent-green/15 text-accent-green",
  reloading: "bg-blue/15 text-blue",
  idle_shutdown: "bg-accent-amber/15 text-accent-amber",
  crashed: "bg-accent-red/15 text-accent-red",
};

function MiniStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg bg-bg-primary/50 p-2.5">
      <p className="text-[10px] uppercase tracking-wider text-text-tertiary">{label}</p>
      <p className="text-sm font-mono font-semibold text-text-primary mt-0.5">{value}</p>
    </div>
  );
}

export function BackendSlotsPanel({ cap }: { cap: MyBackendCapacity }) {
  return (
    <div className="space-y-3">
      <div className="grid grid-cols-3 gap-2.5">
        <MiniStat label="GPU active" value={`${cap.gpu_memory_active_gb.toFixed(1)} GB`} />
        <MiniStat label="GPU peak" value={`${cap.gpu_memory_peak_gb.toFixed(1)} GB`} />
        <MiniStat label="GPU cache" value={`${cap.gpu_memory_cache_gb.toFixed(1)} GB`} />
      </div>

      {cap.slots.length > 0 ? (
        <div className="space-y-2">
          {cap.slots.map((s) => {
            // active / max potential = the token-budget the coordinator admits against.
            const headroom = s.max_tokens_potential > 0 ? (s.active_tokens / s.max_tokens_potential) * 100 : 0;
            return (
              <div key={s.model} className="rounded-lg bg-bg-tertiary/40 px-3 py-2 space-y-1.5">
                <div className="flex items-center justify-between gap-2">
                  <span className="text-xs font-mono text-text-secondary truncate">{shortModelName(s.model)}</span>
                  <div className="flex items-center gap-2 shrink-0">
                    <span
                      className={`px-1.5 py-0.5 rounded text-[10px] font-semibold uppercase ${
                        STATE_TAG[s.state] || "bg-text-tertiary/15 text-text-tertiary"
                      }`}
                    >
                      {s.state}
                    </span>
                    <span className="text-[11px] font-mono text-text-tertiary">
                      {s.num_running} run · {s.num_waiting} wait
                    </span>
                  </div>
                </div>
                {s.max_tokens_potential > 0 && (
                  <div className="flex items-center gap-2">
                    <MeterBar
                      value={clampPct(headroom)}
                      colorClass="bg-accent-brand"
                      height="h-1"
                      label={`Token budget ${abbreviateNumber(s.active_tokens)} of ${abbreviateNumber(s.max_tokens_potential)}`}
                    />
                    <span className="text-[10px] font-mono text-text-tertiary shrink-0">
                      {abbreviateNumber(s.active_tokens)}/{abbreviateNumber(s.max_tokens_potential)} tok
                    </span>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      ) : (
        <p className="text-xs text-text-tertiary">No active backend slots.</p>
      )}
    </div>
  );
}
