import type { NativeModel } from '../../../shared/contracts';
import { earned, type ProviderInsights } from '../insights/types';

export type ModelEarnings = (ReadonlyMap<string, bigint> & { historyComplete?: boolean }) | null;
export function modelEarnings(insights: ProviderInsights | null): ModelEarnings {
  if (!insights) return null;
  const amounts = new Map<string, bigint>();
  for (const row of insights.models) {
    if (row.id) amounts.set(row.id, (amounts.get(row.id) ?? 0n) + earned(row));
  }
  return Object.assign(amounts, { historyComplete: insights.history_complete });
}

/** Stable descending order; absent account data must not pretend to be zero earnings. */
export function rankModels(models: NativeModel[], earnings: ModelEarnings): NativeModel[] {
  if (!earnings) return models;
  return [...models].sort((a, b) => {
    const left = earnings.get(a.id) ?? 0n;
    const right = earnings.get(b.id) ?? 0n;
    return left > right ? -1 : left < right ? 1 : 0;
  });
}
