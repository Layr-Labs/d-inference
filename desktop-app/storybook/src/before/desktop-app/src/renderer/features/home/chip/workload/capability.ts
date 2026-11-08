import type { ChipAnatomy } from '../anatomy';
import { clamp } from '../geometry';

/** Rough per-chip throughput used to pace the illustration; scales with GPU size and bandwidth. */
export function chipCapability(anatomy: ChipAnatomy) {
  return {
    prefillTokensPerSecond: clamp(600 + 30 * anatomy.gpuCores, 900, 3200),
    decodeTokensPerSecond: clamp(25 + anatomy.bandwidthGBs * 0.07, 35, 80),
    arrivalsPerSecond: 0.3 + 0.004 * anatomy.gpuCores,
  };
}
export type ChipCapability = ReturnType<typeof chipCapability>;
