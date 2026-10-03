import type { HardwareSample } from '../../../../../shared/hardware';
import { count } from '../../../../format';

const DASH = '—';

/** Measured figures as printed; anything unknown or out of date reads as a dash, never 0. */
export interface HardwareReadout {
  gpu: string;
  /** Darkbloom's part of the GPU busy time; null while the provider is not serving. */
  darkbloom: string | null;
  power: string;
  clock: string;
  memory: string;
  memoryEstimated: boolean;
  cpu: string;
}

const finite = (value: number | null | undefined): value is number =>
  typeof value === 'number' && Number.isFinite(value);
const percent = (value: number | null | undefined) =>
  finite(value) ? `${Math.round(Math.min(1, Math.max(0, value)) * 100)}%` : DASH;

export function hardwareReadout(sample: HardwareSample | null, fresh: boolean): HardwareReadout {
  const current = fresh ? sample : null,
    gpu = current?.gpu,
    load = current?.cpu.load.filter(finite) ?? [];
  const power = gpu?.power_w,
    clock = gpu?.frequency_mhz,
    bandwidth = current?.memory.bandwidth_gbps;
  return {
    gpu: percent(gpu?.utilization),
    darkbloom:
      current?.provider.running && finite(gpu?.utilization) && finite(gpu?.provider_share)
        ? percent(gpu.utilization * gpu.provider_share)
        : null,
    power: finite(power) ? `${power < 10 ? power.toFixed(1) : Math.round(power)} W` : DASH,
    clock: finite(clock) ? `${count(clock)} MHz` : DASH,
    memory: finite(bandwidth) ? `${count(bandwidth)} GB/s` : DASH,
    memoryEstimated: current?.capabilities.memory_bandwidth === 'estimated',
    cpu: load.length ? percent(load.reduce((sum, value) => sum + value, 0) / load.length) : DASH,
  };
}
