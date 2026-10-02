import type { Leader } from '../../../shared/contracts';
import { GRID_COLS, GRID_NORTH, GRID_ROWS, GRID_SOUTH } from './world-grid';

export interface Region {
  name: string;
  country: string;
  providers: number;
  col: number;
  row: number;
}
// Only public, aggregated regions supplied by the native backend can light the map.
export function regionsFrom(value: unknown): Region[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    if (!entry || typeof entry !== 'object') return [];
    const { latitude, longitude, providers, region, country } = entry;
    if (
      !Number.isFinite(latitude) ||
      !Number.isFinite(longitude) ||
      latitude > GRID_NORTH ||
      latitude <= GRID_SOUTH ||
      Math.abs(longitude) > 180 ||
      !Number.isSafeInteger(providers) ||
      providers <= 0 ||
      typeof region !== 'string' ||
      typeof country !== 'string'
    )
      return [];
    return [
      {
        name: region,
        country,
        providers,
        col: Math.min(GRID_COLS - 1, Math.floor(((longitude + 180) / 360) * GRID_COLS)),
        row: Math.floor(((GRID_NORTH - latitude) / (GRID_NORTH - GRID_SOUTH)) * GRID_ROWS),
      },
    ];
  });
}

export function annualPace(micro?: string) {
  if (!micro || !/^\d+$/.test(micro)) return '—';
  // Round only for display; retain the precise 24-hour amount in the details.
  const dollars = (BigInt(micro) * 365n + 500_000n) / 1_000_000n;
  return `$${dollars.toLocaleString('en-US')}`;
}

// An older native API returned all-time token rankings. Require the scope before
// calculating a 24-hour pace so an old runtime cannot silently mislabel income.
export function parseLeaderboard(value: unknown): Leader[] {
  if (!value || typeof value !== 'object') throw new Error('Missing rankings');
  const data = value as Record<string, unknown>;
  if (data.metric !== 'earnings' || data.window !== '24h' || !Array.isArray(data.entries))
    throw new Error('Unsupported leaderboard scope');
  return data.entries.map((entry: unknown) => {
    if (!entry || typeof entry !== 'object') throw new Error('Invalid provider');
    const row = entry as Record<string, unknown>;
    if (
      typeof row.name !== 'string' ||
      !row.name ||
      !Number.isSafeInteger(row.rank) ||
      Number(row.rank) < 1 ||
      typeof row.tokens !== 'string' ||
      !/^\d+$/.test(row.tokens) ||
      typeof row.earnings_micro_usd !== 'string' ||
      !/^\d+$/.test(row.earnings_micro_usd)
    )
      throw new Error('Invalid provider ranking');
    return {
      rank: Number(row.rank),
      name: row.name,
      tokens: row.tokens,
      earnings_micro_usd: row.earnings_micro_usd,
    };
  });
}
