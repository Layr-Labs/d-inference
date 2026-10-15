import { money as exactMoney } from '../../format';

export interface InsightAmounts {
  work_micro_usd: bigint;
  base_reward_micro_usd: bigint;
  jobs: bigint;
  prompt_tokens: bigint;
  completion_tokens: bigint;
}
export interface InsightSlice extends InsightAmounts {
  id: string;
  available?: boolean;
  complete?: boolean;
}
export interface ProviderInsights {
  account_id: string;
  window: '7d' | '30d';
  history_complete: boolean;
  since: string;
  as_of: string;
  lifetime: {
    count: bigint;
    total_micro_usd: bigint;
    prompt_tokens: bigint | null;
    completion_tokens: bigint | null;
  };
  totals: InsightAmounts;
  days: InsightSlice[];
  models: InsightSlice[];
  machines: InsightSlice[];
}
const integer = (value: unknown) => {
  if (typeof value !== 'string' || !/^\d+$/.test(value))
    throw new Error('Invalid earnings counter');
  return BigInt(value);
};
function amounts(value: Record<string, unknown>): InsightAmounts {
  return {
    work_micro_usd: integer(value.work_micro_usd),
    base_reward_micro_usd: integer(value.base_reward_micro_usd),
    jobs: integer(value.jobs),
    prompt_tokens: integer(value.prompt_tokens),
    completion_tokens: integer(value.completion_tokens),
  };
}
export function parseInsights(value: any): ProviderInsights {
  if (
    !value ||
    typeof value.account_id !== 'string' ||
    !['7d', '30d'].includes(value.window) ||
    (value.history_complete !== undefined && typeof value.history_complete !== 'boolean') ||
    !Number.isFinite(Date.parse(value.as_of))
  )
    throw new Error('Invalid earnings snapshot');
  const rows = (data: any) => {
    if (!Array.isArray(data)) throw new Error('Invalid earnings breakdown');
    return data.map((row) => {
      if (typeof row.id !== 'string') throw new Error('Invalid earnings row');
      if (
        [row.available, row.complete].some(
          (flag) => flag !== undefined && typeof flag !== 'boolean',
        )
      )
        throw new Error('Invalid earnings coverage');
      return { id: row.id, ...amounts(row), available: row.available, complete: row.complete };
    });
  };
  return {
    account_id: value.account_id,
    window: value.window,
    history_complete: value.history_complete !== false,
    since: value.since,
    as_of: value.as_of,
    lifetime: {
      count: integer(value.lifetime.count),
      total_micro_usd: integer(value.lifetime.total_micro_usd),
      prompt_tokens:
        value.lifetime.prompt_tokens === null ? null : integer(value.lifetime.prompt_tokens),
      completion_tokens:
        value.lifetime.completion_tokens === null
          ? null
          : integer(value.lifetime.completion_tokens),
    },
    totals: amounts(value.totals),
    days: rows(value.days),
    models: rows(value.models),
    machines: rows(value.machines),
  };
}
export const money = (value: bigint) => {
  if (value > 0n && value < 10000n) return `$0.${value.toString().padStart(6, '0')}`;
  return exactMoney(value.toString());
};
export const earned = (value: InsightAmounts) => value.work_micro_usd + value.base_reward_micro_usd;
export const percent = (value: bigint, total: bigint) =>
  total > 0n ? Number((value * 100_000n) / total) / 1000 : 0;
export const dayLabel = (id: string) =>
  new Date(`${id}T00:00:00Z`).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC',
  });
export const maximum = (values: bigint[]) => values.reduce((a, b) => (a > b ? a : b), 1n);
