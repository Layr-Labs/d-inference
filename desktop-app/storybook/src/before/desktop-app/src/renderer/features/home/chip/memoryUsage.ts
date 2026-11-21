import type { Snapshot } from '../../../../shared/contracts';

/** MLX active + buffer cache belong to Darkbloom, unlike whole-device driver memory. */
export function providerMemory(state: Snapshot): number | null {
  const active = state.memory.active_gb;
  return typeof active === 'number' && Number.isFinite(active) && active >= 0
    ? active + Math.max(0, state.memory.cache_gb ?? 0)
    : null;
}
export function otherMemory(
  used: number | null | undefined,
  provider: number | null,
): number | null {
  return typeof used === 'number' && Number.isFinite(used) && provider !== null
    ? Math.max(0, used - provider)
    : null;
}
