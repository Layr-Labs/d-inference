import { describe, expect, it } from 'vitest';
import { chipAnatomy } from '../src/renderer/features/home/chip/anatomy';
import { hardwareReadout } from '../src/renderer/features/home/chip/hardware/readouts';
import type { ChipStats } from '../src/renderer/features/home/chip/hooks/useChipWorkload';
import { memoryMap } from '../src/renderer/features/home/chip/memoryMap';
import { stageText } from '../src/renderer/features/home/chip/stageText';
import type { LiveReading } from '../src/renderer/features/home/chip/workload/live';
import { IDLE_INPUTS } from '../src/renderer/features/home/chip/workload/types';
import { previewHardwareSample } from '../src/renderer/previewHardware';

const anatomy = chipAnatomy('Apple M3 Ultra', 192);
const models = [
  { id: 'a', name: 'Alpha 7B', gb: 5 },
  { id: 'b', name: 'Beta 20B', gb: 14 },
  { id: 'c', name: 'Gamma 70B', gb: 40 },
];
const stats: ChipStats = {
  phase: 'decode',
  tokensPerSecond: 412,
  running: 5,
  waiting: 1,
  prefill: 0,
  decode: 0.6,
  kv: 0.3,
  traffic: 0.8,
  neural: 0,
};
const reading = (fresh: boolean): LiveReading => ({
  fresh,
  sample: { at: 1, tokens: 10n, requests: 1n, tokensPerSecond: 333, requestsPerSecond: 1 },
  inputs: { ...IDLE_INPUTS, mode: fresh ? 'live' : 'idle', running: 7, waiting: 2 },
});
const base = { anatomy, memory: memoryMap(192, models), stats, measured: null };

describe('stage text', () => {
  it('labels preview numbers as simulated and names memory and models', () => {
    const text = stageText({
      ...base,
      preview: true,
      provider: 'running',
      reading: reading(false),
    });
    expect(text).toMatchObject({
      mode: 'Simulated activity',
      current: true,
      tokensPerSecond: 412,
      running: 5,
      waiting: 1,
      memoryLine: '192 GB unified memory',
      modelsLine: 'Alpha 7B · Beta 20B +1',
    });
    expect(text.summary).toBe(
      'Apple M3 Ultra: decode, generating tokens. 5 in progress, 1 waiting, about 410 tokens per second.',
    );
  });

  it('prints live snapshot numbers only while they are current', () => {
    expect(
      stageText({ ...base, preview: false, provider: 'draining', reading: reading(true) }),
    ).toMatchObject({ mode: 'Simulated activity', tokensPerSecond: 333, running: 7, waiting: 2 });
    const waiting = stageText({
      ...base,
      preview: false,
      provider: 'running',
      reading: reading(false),
    });
    expect(waiting).toMatchObject({
      mode: 'Simulated activity',
      current: false,
      tokensPerSecond: null,
      running: null,
      waiting: null,
    });
    expect(waiting.summary).toContain('Waiting for current activity.');
    expect(
      stageText({ ...base, preview: false, provider: 'stale', reading: reading(false) }),
    ).toMatchObject({ mode: 'Simulated activity', running: null });
  });

  it('says the chip is live from this Mac while fresh measurements drive it', () => {
    const measured = hardwareReadout(previewHardwareSample(16, true), true);
    const text = stageText({
      ...base,
      preview: false,
      provider: 'running',
      reading: reading(true),
      measured,
    });
    expect(text).toMatchObject({ mode: 'Live from this Mac', measured: true, running: 7 });
    expect(text.summary).toContain('GPU 99% busy.');
    expect(
      stageText({
        ...base,
        preview: false,
        provider: 'stopped',
        reading: reading(false),
        measured,
      }),
    ).toMatchObject({ mode: 'Live from this Mac', running: null });
  });

  it('reports a stopped or starting provider without numbers', () => {
    const stopped = stageText({
      ...base,
      preview: true,
      provider: 'stopped',
      reading: reading(false),
    });
    expect(stopped).toMatchObject({ mode: 'Provider stopped', running: null });
    expect(stopped.summary).toBe('Apple M3 Ultra: provider stopped.');
    const starting = stageText({
      ...base,
      preview: false,
      provider: 'starting',
      reading: reading(false),
    });
    expect(starting).toMatchObject({ mode: 'Provider starting', tokensPerSecond: null });
    expect(starting.summary).toBe('Apple M3 Ultra: provider starting.');
    expect(
      stageText({
        ...base,
        anatomy: chipAnatomy('Apple M1', 0),
        memory: memoryMap(0, []),
        preview: true,
        provider: 'running',
        reading: reading(false),
      }),
    ).toMatchObject({ memoryLine: 'Unified memory', modelsLine: 'No model loaded' });
  });
});
