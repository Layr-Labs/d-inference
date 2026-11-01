import type { RequestHistory, RequestRecord } from '../../../../shared/contracts';

export type Outcome = RequestRecord['outcome'];
export interface RequestFilter {
  model: string;
  outcome: Outcome | 'all';
}
export const outcomes: Record<Outcome, string> = {
  settled: 'Settled',
  completed: 'Completed',
  cancelled: 'Cancelled',
  failed: 'Failed',
};

const finite = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value);
const tokenCount = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
const optional = <T>(value: T | null | undefined) => (value === null ? undefined : value);

function parseRecord(value: unknown): RequestRecord {
  const record = (value || {}) as Record<string, unknown>;
  const earnings = optional(record.earnings_micro_usd);
  if (
    typeof record.id !== 'string' ||
    !(finite(record.started_at) || finite(record.settled_at) || finite(record.completed_at)) ||
    (record.started_at !== undefined && !finite(record.started_at)) ||
    (record.completed_at !== undefined && !finite(record.completed_at)) ||
    (record.settled_at !== undefined && !finite(record.settled_at)) ||
    typeof record.model !== 'string' ||
    !tokenCount(record.input_tokens) ||
    !tokenCount(record.output_tokens) ||
    (record.duration_ms !== undefined && (!finite(record.duration_ms) || record.duration_ms < 0)) ||
    typeof record.outcome !== 'string' ||
    !Object.hasOwn(outcomes, record.outcome) ||
    (earnings !== undefined && (typeof earnings !== 'string' || !/^\d+$/.test(earnings)))
  )
    throw new Error('Invalid request record');
  return {
    id: record.id,
    ...(record.started_at !== undefined ? { started_at: record.started_at as number } : {}),
    ...(record.settled_at !== undefined ? { settled_at: record.settled_at as number } : {}),
    ...(record.completed_at !== undefined ? { completed_at: record.completed_at as number } : {}),
    model: record.model,
    input_tokens: record.input_tokens,
    output_tokens: record.output_tokens,
    duration_ms: record.duration_ms as number | undefined,
    outcome: record.outcome as Outcome,
    earnings_micro_usd: earnings,
  };
}

// Newest first; unknown fields are dropped and malformed history is rejected.
export function parseRequestHistory(value: unknown): RequestHistory {
  const data = (value || {}) as Record<string, unknown>;
  const since = optional(data.since);
  if (
    !finite(data.observed_at) ||
    !Array.isArray(data.records) ||
    !(since === undefined || finite(since))
  )
    throw new Error('Invalid request history');
  return {
    observed_at: data.observed_at,
    since,
    records: data.records.map(parseRecord).sort((a, b) => requestTime(b) - requestTime(a)),
  };
}

export const filterRequests = (records: RequestRecord[], { model, outcome }: RequestFilter) =>
  records.filter(
    (record) =>
      (model === 'all' || record.model === model) &&
      (outcome === 'all' || record.outcome === outcome),
  );

export const requestModels = (records: RequestRecord[]) =>
  [...new Set(records.map((record) => record.model))].sort();

export const requestTime = (record: RequestRecord) =>
  record.settled_at ?? record.completed_at ?? record.started_at!;

export const tokensPerSecond = ({ output_tokens, duration_ms }: RequestRecord) =>
  output_tokens > 0 && duration_ms !== undefined && duration_ms > 0
    ? output_tokens / (duration_ms / 1000)
    : undefined;

export function duration(ms: number) {
  if (ms < 1000) return `${Math.round(ms)} ms`;
  if (ms < 59_950) return `${(ms / 1000).toFixed(1)} s`;
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
}

export const settledEarnings = (records: RequestRecord[]) =>
  records.reduce((sum, record) => sum + BigInt(record.earnings_micro_usd ?? 0), 0n);
