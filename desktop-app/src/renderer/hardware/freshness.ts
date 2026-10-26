import type { HardwareSample } from '../../shared/hardware';

// The runtime samples at 1 Hz; three missed windows means the feed stopped.
export const hardwareFreshnessMs = 3000;

export function msUntilStale(sample: HardwareSample | null, now = Date.now()) {
  return sample ? sample.sampled_at * 1000 + hardwareFreshnessMs - now : 0;
}

export const isFresh = (sample: HardwareSample | null, now = Date.now()) =>
  msUntilStale(sample, now) > 0;

// The snapshot read and the stream race; never let an older sample replace a newer one.
export const newerSample = (current: HardwareSample | null, next: HardwareSample) =>
  current && current.sampled_at >= next.sampled_at ? current : next;
