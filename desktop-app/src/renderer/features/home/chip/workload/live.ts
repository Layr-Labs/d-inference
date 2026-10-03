import type { Snapshot } from '../../../../../shared/contracts';
import { activityFresh } from '../../../stats/data';
import { clamp } from '../geometry';
import { IDLE_INPUTS, type WorkloadInputs } from './types';

/** Counter baseline from one runtime snapshot, with the rates measured against the previous one. */
export interface LiveSample {
  at: number;
  tokens: bigint | null;
  requests: bigint | null;
  tokensPerSecond: number;
  requestsPerSecond: number;
}
export interface LiveReading {
  inputs: WorkloadInputs;
  sample: LiveSample | null;
  fresh: boolean;
}
const MIN_WINDOW = 1,
  MAX_WINDOW = 30,
  MAX_TOKENS_PER_SECOND = 100_000,
  MAX_REQUESTS_PER_SECOND = 1_000;

const counter = (value?: string) => (value && /^\d+$/.test(value) ? BigInt(value) : null);

/** The provider process is up, though a stale status means its activity is unknown. */
export const providerUp = (state: Snapshot['state']) =>
  state === 'running' || state === 'draining' || state === 'stale';

/** Rates over the interval since `previous`; resets on counter decreases or long gaps. */
export function nextSample(
  previous: LiveSample | null,
  at: number,
  tokens: bigint | null,
  requests: bigint | null,
): LiveSample {
  const baseline = { at, tokens, requests, tokensPerSecond: 0, requestsPerSecond: 0 };
  if (!previous || previous.tokens === null || tokens === null) return baseline;
  const window = at - previous.at;
  if (window >= 0 && window < MIN_WINDOW) return previous;
  if (window < 0 || window > MAX_WINDOW || tokens < previous.tokens) return baseline;
  const requestDelta =
    requests !== null && previous.requests !== null && requests >= previous.requests
      ? Number(requests - previous.requests)
      : 0;
  return {
    ...baseline,
    tokensPerSecond: clamp(Number(tokens - previous.tokens) / window, 0, MAX_TOKENS_PER_SECOND),
    requestsPerSecond: clamp(requestDelta / window, 0, MAX_REQUESTS_PER_SECOND),
  };
}

/** Maps a runtime snapshot onto workload targets. Never invents activity for stale data. */
export function readLive(
  state: Snapshot,
  models: string[],
  previous: LiveSample | null,
  now: number,
): LiveReading {
  if (!providerUp(state.state))
    return { inputs: { ...IDLE_INPUTS, mode: 'stopped' }, sample: null, fresh: false };
  const sample = nextSample(
    previous,
    state.observed_at,
    counter(state.activity.tokens),
    counter(state.activity.requests),
  );
  if (!activityFresh(state, now)) return { inputs: IDLE_INPUTS, sample, fresh: false };
  const slots = (state.activity.models || []).filter((slot) =>
    ['running', 'idle'].includes(slot.state),
  );
  const sum = (list: typeof slots, key: 'running' | 'waiting') =>
    list.reduce((total, slot) => total + Math.max(0, slot[key] || 0), 0);
  return {
    inputs: {
      mode: 'live',
      running: sum(slots, 'running'),
      waiting: sum(slots, 'waiting'),
      tokensPerSecond: sample.tokensPerSecond,
      requestsPerSecond: sample.requestsPerSecond,
      runningByModel: models.map((id) =>
        sum(
          slots.filter((slot) => slot.model === id),
          'running',
        ),
      ),
    },
    sample,
    fresh: true,
  };
}
