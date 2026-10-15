import { count } from '../../format';
import type { TrafficPoint } from './data';

export const MAX_TOKEN_BARS = 48;

export interface TokenBar {
  at: number;
  input?: number;
  cached?: number;
  output: number;
  total: number;
}

export const tokenSeries = [
  { key: 'input', label: 'Input tokens' },
  { key: 'cached', label: 'Cached input tokens' },
  { key: 'output', label: 'Output tokens' },
] as const;

// A prompt split is only summed when every interval in the bar reported it; a partial sum would
// read as a real drop in prompt traffic.
const sumAll = (values: (number | undefined)[]) =>
  values.every((value) => value !== undefined)
    ? values.reduce<number>((sum, value) => sum + value!, 0)
    : undefined;

export function tokenBars(points: TrafficPoint[], maxBars = MAX_TOKEN_BARS): TokenBar[] {
  const size = Math.max(1, Math.ceil(points.length / maxBars));
  const bars: TokenBar[] = [];
  for (let start = 0; start < points.length; start += size) {
    const chunk = points.slice(start, start + size);
    const input = sumAll(chunk.map((point) => point.input));
    const cached = sumAll(chunk.map((point) => point.cached));
    const output = chunk.reduce((sum, point) => sum + point.tokens, 0);
    bars.push({
      at: chunk.at(-1)!.at,
      ...(input !== undefined && { input }),
      ...(cached !== undefined && { cached }),
      output,
      total: output + (input ?? 0) + (cached ?? 0),
    });
  }
  return bars;
}

export const reportsPromptTokens = (bars: TokenBar[]) =>
  bars.some((bar) => bar.input !== undefined || bar.cached !== undefined);

export function describeTokenBar(bar: TokenBar) {
  const amount = (value?: number) => (value === undefined ? 'not reported' : count(value));
  return [
    `Input ${amount(bar.input)}`,
    `Cached input ${amount(bar.cached)}`,
    `Output ${amount(bar.output)}`,
    `Total ${count(bar.total)} tokens`,
  ].join(' · ');
}
