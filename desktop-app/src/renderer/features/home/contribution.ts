import type { Snapshot } from '../../../shared/contracts';
import { count, money } from '../../format';

const integer = (value: string | null | undefined) =>
  value != null && /^\d+$/.test(value) ? BigInt(value) : null;

/** Cached input is part of input; reasoning is part of output. Neither is added twice. */
export function contribution(activity: Snapshot['activity']) {
  const output = integer(activity.processed_output_tokens ?? activity.tokens);
  const input = integer(activity.processed_input_tokens ?? activity.prompt_tokens);
  const verified = integer(activity.processed_tokens);
  const gaps = (integer(activity.usage_gaps) ?? 0n) > 0n;
  const total = verified ?? (input !== null && output !== null && !gaps ? input + output : null);
  const pending = integer(activity.pending_usage_requests);
  return {
    tokens: count(total),
    label: 'Tokens processed this session',
    input: count(input),
    output: count(output),
    cached: count(integer(activity.cached_input_tokens)),
    reasoning: count(integer(activity.reasoning_tokens)),
    pending: pending !== null && pending > 0n ? count(pending) : null,
    note:
      total === null
        ? 'Waiting for complete input and output usage'
        : activity.usage_source === 'settled-history'
          ? 'Confirmed input + output from this Mac’s session history; updates after settlement'
          : 'Input + output, including cached input and reasoning',
    earnings: money(activity.earnings_micro_usd ?? undefined, 4),
  };
}
