import type { CoolingData } from '../../../shared/contracts';

/** Readings older than a minute no longer describe the fans. */
export const coolingStale = (cooling?: CoolingData) =>
  cooling?.observed_at != null && Date.now() / 1000 - cooling.observed_at > 60;

export function coolingStatus(cooling?: CoolingData): string {
  if (!cooling) return 'Checking fans';
  if (cooling.error || cooling.mode === 'unavailable' || coolingStale(cooling))
    return 'Fan status unavailable';
  // The policy can be enabled while macOS controls the fans below its threshold.
  if (cooling.enabled != null) return cooling.enabled ? 'Auto fan on' : 'Auto fan off';
  return cooling.mode === 'manual' ? 'Darkbloom control' : 'macOS control';
}
