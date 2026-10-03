import { describe, expect, it } from 'vitest';
import { chipAnatomy } from '../src/renderer/features/home/chip/anatomy';
import { distribute } from '../src/renderer/features/home/chip/workload/distribute';
import { createWorkloadEngine } from '../src/renderer/features/home/chip/workload/engine';
import {
  IDLE_INPUTS,
  type WorkloadFrame,
  type WorkloadInputs,
} from '../src/renderer/features/home/chip/workload/types';

const anatomy = chipAnatomy('Apple M4 Max', 64);
const synthetic: WorkloadInputs = { ...IDLE_INPUTS, mode: 'synthetic' };
const live = (running: number, tokensPerSecond: number, extra: Partial<WorkloadInputs> = {}) => ({
  ...IDLE_INPUTS,
  mode: 'live' as const,
  running,
  tokensPerSecond,
  runningByModel: [running],
  ...extra,
});
function run(
  engine: ReturnType<typeof createWorkloadEngine>,
  seconds: number,
  inputs: WorkloadInputs,
) {
  const frames: WorkloadFrame[] = [];
  for (let i = 0; i < Math.round(seconds * 30); i++) frames.push(engine.step(1 / 30, inputs));
  return frames;
}
const levels = (frame: WorkloadFrame) => [
  frame.power,
  frame.resident,
  frame.prefill,
  frame.decode,
  frame.memoryRead,
  frame.kvFill,
  frame.kvWrite,
  frame.cpu,
  frame.stepPhase,
  ...frame.decodeByModel,
];

describe('workload engine', () => {
  it('replays identically for the same seed and diverges for another', () => {
    const a = createWorkloadEngine({ seed: 7, anatomy, models: 2, warmup: 5 }),
      b = createWorkloadEngine({ seed: 7, anatomy, models: 2, warmup: 5 }),
      c = createWorkloadEngine({ seed: 8, anatomy, models: 2, warmup: 5 });
    const first = run(a, 20, synthetic),
      second = run(b, 20, synthetic),
      other = run(c, 20, synthetic);
    expect(second).toEqual(first);
    expect(other).not.toEqual(first);
  });

  it('keeps synthetic traffic within the concurrency cap and shows both phases', () => {
    const frames = run(createWorkloadEngine({ seed: 3, anatomy, models: 2 }), 60, synthetic);
    expect(Math.max(...frames.map((frame) => frame.running))).toBeLessThanOrEqual(8);
    expect(frames.some((frame) => frame.prefill > 0.5)).toBe(true);
    expect(frames.some((frame) => frame.decode > 0.3)).toBe(true);
    expect(frames.some((frame) => frame.kvFill > 0.1)).toBe(true);
    for (const frame of frames)
      for (const level of levels(frame)) {
        expect(level).toBeGreaterThanOrEqual(0);
        expect(level).toBeLessThanOrEqual(1);
      }
  });

  it('goes dark when the provider is stopped', () => {
    const engine = createWorkloadEngine({ seed: 1, anatomy, models: 2, warmup: 20 });
    expect(run(engine, 1, synthetic).at(-1)!.power).toBeGreaterThan(0.9);
    const stopped = run(engine, 5, { ...IDLE_INPUTS, mode: 'stopped' }).at(-1)!;
    expect(stopped.phase).toBe('stopped');
    expect(stopped.running).toBe(0);
    for (const level of levels(stopped)) expect(level).toBeLessThan(0.01);
  });

  it('floods the GPU with prefill when requests arrive', () => {
    const engine = createWorkloadEngine({ seed: 2, anatomy, models: 1 });
    run(engine, 1, live(0, 0));
    const before = engine.frame;
    const frames = run(engine, 0.6, live(4, 0)),
      after = frames.at(-1)!;
    expect(before.prefill).toBeLessThan(0.01);
    expect(after.prefill).toBeGreaterThan(0.5);
    expect(after.sinceArrival).toBeLessThan(0.6);
    expect(after.sinceFlood).toBeLessThan(0.6);
    expect(after.kvFill).toBeGreaterThan(before.kvFill);
    expect(Math.max(...frames.map((frame) => frame.cpu))).toBeGreaterThan(0.5);
  });

  it('decodes from observed throughput and releases KV when requests finish', () => {
    const engine = createWorkloadEngine({ seed: 4, anatomy, models: 1 });
    const busy = run(engine, 6, live(6, 320)).at(-1)!;
    expect(busy.decode).toBeGreaterThan(0.5);
    expect(busy.memoryRead).toBeGreaterThan(0.5);
    expect(busy.kvFill).toBeGreaterThan(0.2);
    expect(busy.running).toBe(6);
    const quiet = run(engine, 0.5, live(6, 0)).at(-1)!;
    expect(quiet.decode).toBeLessThan(busy.decode);
    const drained = run(engine, 4, live(0, 0)).at(-1)!;
    expect(drained.kvFill).toBeLessThan(0.05);
    expect(drained.decode).toBeLessThan(0.05);
    expect(drained.phase).toBe('ready');
  });

  it('saturates instead of blowing out under very large live counts', () => {
    const engine = createWorkloadEngine({ seed: 5, anatomy, models: 2 });
    const frames = run(engine, 8, live(25, 4000, { waiting: 3, runningByModel: [18, 7] }));
    const last = frames.at(-1)!;
    expect(last.running).toBe(25);
    expect(last.waiting).toBe(3);
    for (const frame of frames)
      for (const level of levels(frame)) expect(level).toBeLessThanOrEqual(1);
    expect(last.decodeByModel[0]).toBeGreaterThan(last.decodeByModel[1]);
  });

  it('keeps resident weights dark when no model is loaded', () => {
    const engine = createWorkloadEngine({ seed: 6, anatomy, models: 0 });
    expect(run(engine, 3, IDLE_INPUTS).at(-1)!.resident).toBe(0);
  });
});

describe('distribute', () => {
  it('splits a total across models by observed share with largest remainders', () => {
    expect(distribute(10, [18, 7], 2)).toEqual([7, 3]);
    expect(distribute(5, [], 2)).toEqual([5, 0]);
    expect(distribute(3, [1, 1, 1], 3)).toEqual([1, 1, 1]);
    expect(distribute(0, [4, 4], 2)).toEqual([0, 0]);
  });
});
