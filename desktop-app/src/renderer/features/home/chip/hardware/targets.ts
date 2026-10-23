import type { HardwareSample } from '../../../../../shared/hardware';
import type { ChipAnatomy } from '../anatomy';
import { clamp } from '../geometry';
import { hardwarePhase, type HardwarePhase } from './phase';

/** What one fresh sample asks each part of the chip to show; null is unknown, never zero. */
export interface HardwareTargets {
  /** Busy fraction per logical CPU id. */
  cpu: (number | null)[];
  /** Mean busy fraction per anatomy cluster, lighting its shared L2. */
  clusters: (number | null)[];
  cpuBusy: number | null;
  /** Whole-GPU busy fraction; macOS reports no per-core load. */
  gpu: number | null;
  /** Darkbloom's fraction of the busy GPU time; 0 while the provider is stopped. */
  share: number | null;
  /** GPU power against the session peak. */
  glow: number | null;
  /** GPU clock against its maximum. */
  clock: number | null;
  /** DRAM bandwidth against the chip's peak. */
  traffic: number | null;
  trafficEstimated: boolean;
  /** Neural Engine activity: dark unless something actually uses it. */
  ane: number | null;
  /** Memory held by everything except Darkbloom's resident models, as a fraction of RAM. */
  other: number | null;
  phase: HardwarePhase | null;
  /** The GPU is busy and mostly with Darkbloom's work. */
  serving: boolean;
}

/** The power floor keeps idle milliwatts from reading as a full-power glow early in a session. */
const POWER_FLOOR_PER_GPU_CORE_W = 0.5,
  /** Neural Engine bandwidth at which it reads fully lit. */
  ANE_FULL_GBPS = 60,
  SERVING_BUSY = 0.15;

const known = (value: number | null | undefined): value is number =>
  typeof value === 'number' && Number.isFinite(value);
const fraction = (value: number | null | undefined) => (known(value) ? clamp(value) : null);
const ratio = (value: number | null | undefined, peak: number | null | undefined) =>
  known(value) && known(peak) && peak > 0 ? clamp(value / peak) : null;
const mean = (values: (number | null)[]) => {
  const present = values.filter(known);
  return present.length ? present.reduce((sum, value) => sum + value, 0) / present.length : null;
};

/** Highest GPU power seen this session, never below a floor scaled to the GPU's size. */
export const sessionPeakPower = (peak: number, sample: HardwareSample, anatomy: ChipAnatomy) =>
  Math.max(
    peak,
    POWER_FLOOR_PER_GPU_CORE_W * anatomy.gpuCores,
    known(sample.gpu.power_w) ? sample.gpu.power_w : 0,
  );

export function hardwareTargets(
  sample: HardwareSample,
  anatomy: ChipAnatomy,
  peakPowerW: number,
  providerMemoryGb: number | null = null,
): HardwareTargets {
  const { gpu, ane, memory } = sample,
    running = sample.provider.running;
  const cpu = sample.cpu.load.map(fraction),
    busy = fraction(gpu.utilization),
    share = running ? fraction(gpu.provider_share) : 0;
  // Driver GPU memory is whole-device, not attributable to this provider.
  const darkbloomGb = running ? providerMemoryGb : 0,
    usedGb = known(memory.used_gb) ? memory.used_gb : null;
  const aneLevel =
    known(ane.active) || known(ane.bandwidth_gbps)
      ? clamp(
          Math.max(
            known(ane.active) ? ane.active : 0,
            known(ane.bandwidth_gbps) ? ane.bandwidth_gbps / ANE_FULL_GBPS : 0,
          ),
        )
      : null;
  return {
    cpu,
    clusters: anatomy.clusters.map((cluster) => mean(cluster.cpus.map((id) => cpu[id] ?? null))),
    cpuBusy: mean(cpu),
    gpu: busy,
    share,
    glow: ratio(gpu.power_w, peakPowerW),
    clock: ratio(gpu.frequency_mhz, anatomy.gpuMaxMhz),
    traffic: ratio(memory.bandwidth_gbps, anatomy.bandwidthGBs),
    trafficEstimated: sample.capabilities.memory_bandwidth === 'estimated',
    ane: aneLevel,
    other:
      usedGb === null || darkbloomGb === null || anatomy.memoryGb <= 0
        ? null
        : clamp((usedGb - darkbloomGb) / anatomy.memoryGb),
    phase: hardwarePhase(sample),
    serving: busy !== null && share !== null && busy * share >= SERVING_BUSY,
  };
}
