import type { ActivitySample, Snapshot } from '../../../shared/contracts';
export interface TrafficPoint {
  at: number;
  requests: number;
  tokens: number;
  input?: number;
  cached?: number;
}
export interface ModelTraffic {
  id: string;
  name: string;
  requests: number;
  tokens: number;
  speed: number;
  points: TrafficPoint[];
}

const optionalDelta = (current?: number, previous?: number) =>
  current === undefined || previous === undefined ? undefined : current - previous;

export function observedTraffic(state: Snapshot): TrafficPoint[] {
  const samples: ActivitySample[] = state.activity.samples;
  return samples.slice(1).flatMap((sample, index) => {
    const previous = samples[index];
    const input = optionalDelta(sample.input_tokens, previous.input_tokens);
    const cached = optionalDelta(sample.cached_input_tokens, previous.cached_input_tokens);
    if (
      sample.at <= previous.at ||
      sample.requests < previous.requests ||
      sample.tokens < previous.tokens ||
      (input ?? 0) < 0 ||
      (cached ?? 0) < 0
    )
      return [];
    return [
      {
        at: sample.at,
        requests: sample.requests - previous.requests,
        tokens: sample.tokens - previous.tokens,
        ...(input !== undefined && { input }),
        ...(cached !== undefined && { cached }),
      },
    ];
  });
}
export function activityFresh(state: Snapshot, now: number) {
  return (
    ['running', 'draining'].includes(state.state) &&
    Array.isArray(state.activity.models) &&
    !!state.activity.sampled_at &&
    now - state.activity.sampled_at <= 10 &&
    now - state.observed_at <= 10 &&
    !state.operations.some((op) => op.state === 'running')
  );
}
export function curve(points: { x: number; y: number }[]) {
  if (!points.length) return '';
  return points.slice(1).reduce((path, point, i) => {
    const previous = points[i],
      midpoint = (previous.x + point.x) / 2;
    return `${path} C ${midpoint},${previous.y} ${midpoint},${point.y} ${point.x},${point.y}`;
  }, `M ${points[0].x},${points[0].y}`);
}
