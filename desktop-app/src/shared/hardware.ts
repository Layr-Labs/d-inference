// Loopback-only machine load from GET /control/v1/hardware and the
// /control/v1/hardware/events stream. Every nullable number is null while its
// source is unavailable or its counter has not advanced yet; null never means 0.
export const hardwareProtocolVersion = 1;

export type CoreKind = 'super' | 'performance' | 'efficiency';
export type CapabilityStatus = 'measured' | 'estimated' | 'pending' | 'unavailable';
export type HardwareCapability =
  | 'gpu_power'
  | 'gpu_frequency'
  | 'gpu_provider_share'
  | 'memory_bandwidth'
  | 'ane_bandwidth'
  | 'ane_power';

export interface HardwareTopology {
  chip: string;
  model: string;
  cpu: {
    // Fastest tier first; level is hw.perflevelN.
    tiers: { level: number; name: string; kind: CoreKind; cores: number }[];
    // cpus index HardwareSample.cpu.load.
    clusters: { id: number; kind: CoreKind; cpus: number[] }[];
  };
  // groups: enabled cores per GPU partition.
  gpu: { cores: number | null; groups: number[]; max_mhz: number | null };
  ane: { present: boolean };
  memory: { total_gb: number; peak_bandwidth_gbps: number | null };
}

export interface HardwareSample {
  // Epoch seconds.
  sampled_at: number;
  interval_ms: number;
  // Busy fraction 0..1 per logical CPU id.
  cpu: { load: number[] };
  gpu: {
    utilization: number | null;
    frequency_mhz: number | null;
    power_w: number | null;
    // Darkbloom's fraction 0..1 of all GPU time in the window; 0 while the provider is stopped.
    provider_share: number | null;
    memory_in_use_gb: number | null;
  };
  // active: fraction of the window the ANE was powered.
  ane: { active: number | null; bandwidth_gbps: number | null; power_w: number | null };
  // bandwidth_gbps is an estimate from bucketed DRAM histograms.
  memory: {
    used_gb: number | null;
    wired_gb: number | null;
    pressure: 'normal' | 'warn' | 'critical' | null;
    bandwidth_gbps: number | null;
  };
  thermal: { state: 'nominal' | 'fair' | 'serious' | 'critical' };
  provider: { running: boolean };
  capabilities: Partial<Record<HardwareCapability, CapabilityStatus>>;
}

export interface HardwareLoad {
  protocol: number;
  topology: HardwareTopology;
  sample: HardwareSample | null;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

// Structural gate for frames crossing into the renderer: the fields every
// consumer dereferences unconditionally.
export function isHardwareSample(value: unknown): value is HardwareSample {
  return (
    isObject(value) &&
    Number.isFinite(value.sampled_at) &&
    isObject(value.cpu) &&
    Array.isArray(value.cpu.load) &&
    value.cpu.load.every((load) => Number.isFinite(load)) &&
    ['gpu', 'ane', 'memory', 'thermal', 'provider', 'capabilities'].every((key) =>
      isObject(value[key]),
    )
  );
}
