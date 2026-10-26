import type { Leader } from '../../../shared/contracts';

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
