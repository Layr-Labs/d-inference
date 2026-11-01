import type { Machine } from '../../../../shared/contracts';
import { isOnline } from '../fleet';

// The account projection refreshes every few minutes; silence beyond this means the
// reported status can no longer be trusted as current.
export const STALE_AFTER = 15 * 60;

export type Presence = 'online' | 'stale' | 'offline';

export function remotePresence(machine: Machine, now: number): Presence {
  if (!isOnline(machine.status)) return 'offline';
  return !machine.observed_at || now - machine.observed_at > STALE_AFTER ? 'stale' : 'online';
}

export function uptime(seconds: number) {
  const hours = Math.floor(seconds / 3600);
  if (hours >= 48) return `${Math.floor(hours / 24)} days`;
  if (hours >= 1) return `${hours}h ${Math.floor((seconds % 3600) / 60)}m`;
  return `${Math.max(1, Math.floor(seconds / 60))}m`;
}
