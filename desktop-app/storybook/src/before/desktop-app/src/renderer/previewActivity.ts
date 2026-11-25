import type { ActivitySample, RequestHistory, RequestRecord } from '../shared/contracts';
import { previewCacheShare } from './previewStats';

// Development fixture only; imported solely by the explicit preview backend.
const DAY = 86_400;

// Output tokens per hour by local hour of day: quiet overnight, busiest mid-afternoon.
const hourlyRate = (hour: number) =>
  24_000 + 152_000 * (0.5 - 0.5 * Math.cos(((hour - 4) / 24) * 2 * Math.PI));

// The Mac sleeps from 2 to 4 AM, so those hours have no observations.
const asleep = (at: number, now: number) => {
  const hour = new Date(at * 1000).getHours();
  return (hour === 2 || hour === 3) && now - at > 3600;
};

// Cumulative counters sampled about once a minute, as the runtime records them.
export function previewSamples(now: number): ActivitySample[] {
  const samples: ActivitySample[] = [];
  let tokens = 412_300;
  let served = 431;
  let input = 803_900;
  let cached = 392_100;
  for (let at = now - DAY; at <= now; at += 60) {
    if (asleep(at, now)) continue;
    const local = new Date(at * 1000);
    const minute = Math.floor(at / 60);
    const variation = 0.8 + 0.2 * Math.sin(minute / 7) + 0.15 * Math.sin(minute / 23);
    const minuteTokens = Math.round(
      (hourlyRate(local.getHours() + local.getMinutes() / 60) / 60) * variation,
    );
    tokens += minuteTokens;
    served += minuteTokens / 930;
    const prompt = minuteTokens * 2.9;
    const hit = Math.round(prompt * previewCacheShare(at));
    cached += hit;
    input += Math.round(prompt) - hit;
    samples.push({
      at,
      requests: Math.floor(served),
      tokens,
      input_tokens: input,
      cached_input_tokens: cached,
    });
  }
  return samples;
}

// A Mac Studio that has served around the clock except for the hour it spent updating.
export function previewRemoteActivity(now: number) {
  const current = new Date(now * 1000);
  current.setMinutes(0, 0, 0);
  const hourly = Array.from({ length: 24 }, (_, index) => {
    if (index === 9) return null;
    const start = current.getTime() / 1000 - (23 - index) * 3600;
    const share = index === 23 ? (now - start) / 3600 : 1;
    const rate = hourlyRate(new Date(start * 1000).getHours()) * (1.35 + 0.1 * Math.sin(index));
    return Math.round(rate * share);
  });
  const output = hourly.reduce<number>((sum, tokens) => sum + (tokens ?? 0), 0);
  const prompt = output * 3.1;
  const cached = Math.round(prompt * 0.52);
  return {
    hourly_tokens: hourly,
    requests_24h: Math.round(output / 1_120),
    tokens_24h: { input: Math.round(prompt) - cached, cached_input: cached, output },
    online_since: current.getTime() / 1000 - 13 * 3600 + 4 * 60,
    last_paid_at: now - 140,
  };
}

const models = [
  { id: 'gpt-oss-20b', speed: 42, input: 0.4, output: 2 },
  { id: 'gemma-4-26b', speed: 61, input: 0.5, output: 2.5 },
];

export function previewRequestHistory(now: number): RequestHistory {
  let seed = 20_261_002;
  const random = () => {
    seed = (seed * 16_807) % 2_147_483_647;
    return (seed - 1) / 2_147_483_646;
  };
  const records: RequestRecord[] = [];
  for (let at = now - 45, index = 0; records.length < 80; index++) {
    at -= 540 + random() * 720;
    if (asleep(at, now)) continue;
    const model = models[random() < 0.62 ? 0 : 1];
    const input = Math.round(280 + random() ** 2 * 7200);
    const planned = Math.round(90 + random() * 1500);
    const outcome = index % 29 === 11 ? 'failed' : index % 13 === 4 ? 'cancelled' : 'completed';
    const output =
      outcome === 'failed'
        ? 0
        : outcome === 'cancelled'
          ? Math.round(planned * (0.2 + random() * 0.5))
          : planned;
    const prefill = 240 + input / 11;
    records.push({
      id: `preview-request-${index}`,
      started_at: at,
      model: model.id,
      input_tokens: input,
      output_tokens: output,
      duration_ms: Math.round(
        outcome === 'failed' ? prefill + random() * 600 : prefill + (output / model.speed) * 1000,
      ),
      outcome,
      earnings_micro_usd:
        outcome === 'failed'
          ? '0'
          : String(Math.round(input * model.input + output * model.output)),
    });
  }
  return { observed_at: now, since: now - DAY, records };
}
