import type { HardwareLoad, HardwareSample, HardwareTopology } from '../shared/hardware';
// Hardware load design fixture for the explicit development preview path:
// an M4 Max cycling idle, prefill (compute-bound) and decode (bandwidth-bound),
// with magnitudes from measured MLX runs on that chip.

export type PreviewHardwarePhase = 'idle' | 'prefill' | 'decode';

const cycleSeconds = 24;

export const previewTopology: HardwareTopology = {
  chip: 'Apple M4 Max',
  model: 'Mac16,5',
  cpu: {
    tiers: [
      { level: 0, name: 'Performance', kind: 'performance', cores: 12 },
      { level: 1, name: 'Efficiency', kind: 'efficiency', cores: 4 },
    ],
    clusters: [
      { id: 0, kind: 'efficiency', cpus: [0, 1, 2, 3] },
      { id: 1, kind: 'performance', cpus: [4, 5, 6, 7, 8, 9] },
      { id: 2, kind: 'performance', cpus: [10, 11, 12, 13, 14, 15] },
    ],
  },
  gpu: { cores: 40, groups: [10, 10, 10, 10], max_mhz: 1578 },
  ane: { present: true },
  memory: { total_gb: 64, peak_bandwidth_gbps: 546 },
};

// Idle 0–6 s, prefill 6–10 s, decode 10–24 s of each cycle. A stopped
// provider leaves the machine idle apart from background work.
export function previewHardwarePhase(at: number, running: boolean): PreviewHardwarePhase {
  if (!running) return 'idle';
  const t = ((at % cycleSeconds) + cycleSeconds) % cycleSeconds;
  return t < 6 ? 'idle' : t < 10 ? 'prefill' : 'decode';
}

// Smooth deterministic jitter in [-1, 1].
const wave = (at: number, seed: number) =>
  0.6 * Math.sin(at * 1.7 + seed * 2.3) + 0.4 * Math.sin(at * 0.53 + seed * 5.1);
const round = (value: number, places: number) => Number(value.toFixed(places));
const clamp = (value: number) => Math.min(1, Math.max(0, value));

function cpuLoad(at: number, phase: PreviewHardwarePhase) {
  return Array.from({ length: 16 }, (_, cpu) => {
    const efficiency = cpu < 4;
    // The scheduler thread pins one P core; tokenization and IO touch a second.
    const host = phase === 'idle' ? 0 : cpu === 4 ? 0.55 : cpu === 10 ? 0.18 : 0;
    const base = efficiency ? 0.22 : 0.04;
    return round(clamp(base + host + (efficiency ? 0.1 : 0.03) * wave(at, cpu)), 3);
  });
}

export function previewHardwareSample(at: number, running: boolean): HardwareSample {
  const phase = previewHardwarePhase(at, running);
  const busy = phase !== 'idle';
  const power =
    phase === 'prefill' ? 62 + 4 * wave(at, 20) : phase === 'decode' ? 31 + 6 * wave(at, 21) : 0.4;
  const bandwidth =
    phase === 'prefill'
      ? 100 + 40 * wave(at, 22)
      : phase === 'decode'
        ? 448 + 6 * wave(at, 23)
        : 14 + 3 * wave(at, 24);
  const weights = running ? 18.4 : 0;
  return {
    sampled_at: round(at, 3),
    interval_ms: 1000,
    cpu: { load: cpuLoad(at, phase) },
    gpu: {
      utilization: busy ? 0.99 : round(clamp(0.03 + 0.02 * wave(at, 25)), 3),
      frequency_mhz: busy ? 1578 : 338,
      power_w: round(power, 2),
      provider_share: busy ? 0.97 : 0,
      memory_in_use_gb: round(weights + (busy ? 6.2 : 1.1), 2),
    },
    ane: { active: 0, bandwidth_gbps: null, power_w: null },
    memory: {
      used_gb: round(21.5 + weights + (busy ? 6.2 : 0), 2),
      wired_gb: round(4.8 + weights, 2),
      pressure: 'normal',
      bandwidth_gbps: round(bandwidth, 1),
    },
    thermal: { state: phase === 'prefill' ? 'fair' : 'nominal' },
    provider: { running },
    capabilities: {
      gpu_power: 'measured',
      gpu_frequency: 'measured',
      gpu_provider_share: 'measured',
      memory_bandwidth: 'estimated',
      ane_bandwidth: 'pending',
      ane_power: 'unavailable',
    },
  };
}

export function previewHardwareLoad(at: number, running: boolean): HardwareLoad {
  return { protocol: 1, topology: previewTopology, sample: previewHardwareSample(at, running) };
}

export function previewHardwareStream(
  callback: (sample: HardwareSample) => void,
  running: () => boolean,
  intervalMs = 1000,
) {
  const timer = setInterval(
    () => callback(previewHardwareSample(Date.now() / 1000, running())),
    intervalMs,
  );
  return () => clearInterval(timer);
}
