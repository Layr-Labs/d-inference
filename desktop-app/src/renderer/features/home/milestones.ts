import type { NetworkData } from '../../../shared/contracts';

// Proposed network token milestones, not published policy: 1, 2.5 and 5 of each power of ten
// from one billion (… 500B, 1T, 2.5T, 5T, 10T …).
const STEPS = [1, 2.5, 5];
const FIRST = 1e9;

export function nextMilestone(total: number): number {
  if (!Number.isFinite(total)) throw new RangeError('Token total must be finite.');
  for (let scale = FIRST; ; scale *= 10)
    for (const step of STEPS) if (step * scale > total) return step * scale;
}

// Share of the next milestone already processed, so the bar reads as distance to that mark.
export function milestoneProgress(total: number) {
  const next = nextMilestone(total);
  return { next, progress: Math.min(1, Math.max(0, total / next)) };
}

export function networkTokens(network?: NetworkData): number | undefined {
  const total = Number(network?.total_tokens);
  return network?.total_tokens && Number.isFinite(total) ? total : undefined;
}

export type NetworkStatus = 'connecting' | 'live' | 'stale' | 'unavailable';

export function networkStatus(network?: NetworkData): NetworkStatus {
  if (!network) return 'connecting';
  if (networkTokens(network) === undefined) return 'unavailable';
  return network.error ? 'stale' : 'live';
}
