import { describe, expect, it } from 'vitest';
import { measuredFrame } from '../src/renderer/features/home/chip/workload/measured';
import { memoryMap } from '../src/renderer/features/home/chip/memoryMap';
import { createHardwareDrive } from '../src/renderer/features/home/chip/hardware/drive';
import { IDLE_INPUTS } from '../src/renderer/features/home/chip/workload/types';
import {
  gpuLevel,
  cpuLevel,
  tracePulses,
} from '../src/renderer/features/home/chip/render/activity';
import { chipLayout } from '../src/renderer/features/home/chip/layout';
import { chipAnatomy } from '../src/renderer/features/home/chip/anatomy';

const memory = memoryMap(64, [{ id: 'a', name: 'A', gb: 10 }], 14);
const reading = {
  fresh: true,
  sample: null,
  inputs: { ...IDLE_INPUTS, mode: 'live' as const, running: 8, waiting: 2, tokensPerSecond: 300 },
};
describe('live chip frames', () => {
  it('shows real counts and allocation without inventing prompt phases or token motion', () => {
    const frame = measuredFrame(reading, memory, 14);
    expect(frame).toMatchObject({
      running: 8,
      waiting: 2,
      tokensPerSecond: 300,
      resident: 1,
      prefill: 0,
      decode: 0,
      memoryRead: 0,
      kvWrite: 0,
      steps: 0,
    });
    expect(frame.kvFill).toBeCloseTo((14 / 64 - 10 / 64) / (0.9 - 10 / 64));
    expect(measuredFrame(reading, memory, null).kvFill).toBe(0);
  });
  it('withholds stale counts and leaves unmeasured processors and traffic dark', () => {
    const workload = measuredFrame({ ...reading, fresh: false }, memory, 14);
    const lit = createHardwareDrive().step(1, workload, null);
    const frame = { ...lit, motion: true, pointer: null };
    const layout = chipLayout(chipAnatomy('Apple M3 Max', 64), { width: 900, height: 440 });
    expect(workload).toMatchObject({ running: 0, waiting: 0, tokensPerSecond: 0 });
    expect(
      gpuLevel(
        layout.tiles.find((tile) => tile.kind === 'gpu')!,
        frame,
      ),
    ).toEqual({ prefill: 0, decode: 0 });
    expect(
      cpuLevel(
        layout.tiles.find((tile) => tile.kind === 'performance')!,
        frame,
      ),
    ).toBe(0);
    expect(tracePulses(layout.traces[0], frame)).toEqual([]);
  });
});
