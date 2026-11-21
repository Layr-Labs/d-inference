import type { HardwareSample } from '../../../../../shared/hardware';
import type { WorkloadMode, WorkloadPhase } from '../workload/types';

export type HardwarePhase = 'idle' | 'prefill' | 'decode';

/** Below this the GPU is idle as far as the illustration is concerned. */
const BUSY = 0.15;
/**
 * Watts per GB/s of DRAM traffic that separates the two regimes. On an M4 Max prefill draws
 * about 0.4 W per GB/s (compute-bound) and decode about 0.06 (bandwidth-bound); this sits near
 * their geometric mean, and the ratio holds across tiers because power and bandwidth both
 * scale with the GPU's size.
 */
const PREFILL_WATTS_PER_GBPS = 0.15;

/** Which regime the measured GPU is in, or null when the counters cannot tell. */
export function hardwarePhase({ gpu, memory }: HardwareSample): HardwarePhase | null {
  if (gpu.utilization === null) return null;
  if (gpu.utilization < BUSY) return 'idle';
  if (gpu.power_w === null || memory.bandwidth_gbps === null) return null;
  return gpu.power_w / Math.max(1, memory.bandwidth_gbps) >= PREFILL_WATTS_PER_GBPS
    ? 'prefill'
    : 'decode';
}

/**
 * The phase shown. Live provider signals decide prefill versus decode, since the hardware cannot
 * see requests or the KV cache; the measured regime breaks ties when they report both phases,
 * or nothing while the GPU is busy with Darkbloom. Synthetic signals never override a
 * measurement.
 */
export function resolvePhase(
  provider: WorkloadPhase,
  mode: WorkloadMode,
  measured: HardwarePhase | null,
  serving: boolean,
): WorkloadPhase {
  if (provider === 'stopped' || measured === null) return provider;
  const fromHardware: WorkloadPhase = serving && measured !== 'idle' ? measured : 'ready';
  if (mode !== 'live') return fromHardware;
  if (provider === 'mixed') return serving ? fromHardware : provider;
  if (provider === 'ready') return fromHardware;
  return provider;
}
