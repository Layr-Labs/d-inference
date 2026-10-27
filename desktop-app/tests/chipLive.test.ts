import { describe, expect, it } from 'vitest';
import { nextSample, readLive } from '../src/renderer/features/home/chip/workload/live';
import type { Snapshot } from '../src/shared/contracts';

const NOW = 1_800_000_000;
function snapshot(at: number, tokens: string, requests = '10', overrides: Partial<Snapshot> = {}) {
  return {
    state: 'running',
    observed_at: at,
    operations: [],
    activity: {
      tokens,
      requests,
      samples: [],
      sampled_at: at,
      models: [
        { model: 'a', state: 'running', running: 4, waiting: 1 },
        { model: 'b', state: 'idle', running: 2, waiting: 0 },
        { model: 'c', state: 'crashed', running: 9, waiting: 9 },
      ],
    },
    ...overrides,
  } as unknown as Snapshot;
}

describe('live mapping', () => {
  it('derives tokens and requests per second from two snapshots', () => {
    const first = readLive(snapshot(NOW, '1000', '10'), ['a', 'b'], null, NOW);
    expect(first.inputs.tokensPerSecond).toBe(0);
    const second = readLive(snapshot(NOW + 2, '1600', '11'), ['a', 'b'], first.sample, NOW + 2);
    expect(second.fresh).toBe(true);
    expect(second.inputs).toMatchObject({
      mode: 'live',
      running: 6,
      waiting: 1,
      tokensPerSecond: 300,
      requestsPerSecond: 0.5,
      runningByModel: [4, 2],
    });
  });

  it('handles counters past the float-safe range', () => {
    const big = '90071992547409930';
    const first = nextSample(null, NOW, BigInt(big), null);
    const second = nextSample(first, NOW + 4, BigInt(big) + 2000n, null);
    expect(second.tokensPerSecond).toBe(500);
  });

  it('resets on counter decreases, long gaps and keeps rates for the same observation', () => {
    const base = nextSample(null, NOW, 1000n, 1n),
      rated = nextSample(base, NOW + 2, 1400n, 2n);
    expect(rated.tokensPerSecond).toBe(200);
    expect(nextSample(rated, NOW + 2, 1400n, 2n)).toBe(rated);
    expect(nextSample(rated, NOW + 2.5, 1500n, 2n)).toBe(rated);
    expect(nextSample(rated, NOW + 4, 100n, 2n)).toMatchObject({
      tokensPerSecond: 0,
      tokens: 100n,
    });
    expect(nextSample(rated, NOW + 60, 9000n, 3n)).toMatchObject({ tokensPerSecond: 0 });
    expect(nextSample(rated, NOW + 1, 1500n, 3n)).toMatchObject({
      tokensPerSecond: 0,
      at: NOW + 1,
    });
  });

  it('never invents activity for stopped or stale runtimes', () => {
    const stopped = readLive(snapshot(NOW, '1', '1', { state: 'stopped' }), ['a'], null, NOW);
    expect(stopped.inputs).toMatchObject({ mode: 'stopped', running: 0, tokensPerSecond: 0 });
    const starting = readLive(snapshot(NOW, '1', '1', { state: 'starting' }), ['a'], null, NOW);
    expect(starting.inputs.mode).toBe('stopped');
    const outdated = readLive(snapshot(NOW, '1', '1', { state: 'stale' }), ['a'], null, NOW);
    expect(outdated).toMatchObject({ fresh: false, inputs: { mode: 'idle', running: 0 } });
    const stale = readLive(snapshot(NOW - 60, '1'), ['a'], null, NOW);
    expect(stale.fresh).toBe(false);
    expect(stale.inputs).toMatchObject({ mode: 'idle', running: 0, waiting: 0 });
    const unsampled = snapshot(NOW, '1');
    unsampled.activity.models = null;
    expect(readLive(unsampled, ['a'], null, NOW).inputs.mode).toBe('idle');
  });

  it('ignores malformed counters', () => {
    const first = readLive(snapshot(NOW, 'n/a'), ['a'], null, NOW);
    const second = readLive(snapshot(NOW + 2, '500'), ['a'], first.sample, NOW + 2);
    expect(second.inputs.tokensPerSecond).toBe(0);
  });
});
