import { expect, it } from 'vitest';
import { memoryMap } from '../src/renderer/features/home/chip/memoryMap';
import { modelColor } from '../src/renderer/features/home/chip/memoryStyle';
import { otherMemory, providerMemory } from '../src/renderer/features/home/chip/memoryUsage';
import { hardwareTargets } from '../src/renderer/features/home/chip/hardware/targets';
import { anatomyFromTopology } from '../src/renderer/features/home/chip/topologyAnatomy';
import { previewHardwareSample, previewTopology } from '../src/renderer/previewHardware';
import type { Snapshot } from '../src/shared/contracts';

it('uses provider allocator memory, rather than whole-GPU memory, for other-app attribution', () => {
  const state = { memory: { active_gb: 52, cache_gb: 1 } } as Snapshot;
  expect(providerMemory(state)).toBe(53);
  const sample = previewHardwareSample(16, true);
  sample.memory.used_gb = 60;
  sample.gpu.memory_in_use_gb = 16;
  const anatomy = anatomyFromTopology(previewTopology, '', 0);
  expect(hardwareTargets(sample, anatomy, 62, 53).other).toBeCloseTo(7 / 64);
  expect(hardwareTargets(sample, anatomy, 62).other).toBeNull();
  expect(otherMemory(60, 53)).toBe(7);
  expect(otherMemory(60, null)).toBeNull();
});
it('bounds estimated model colors by measured Darkbloom allocation', () => {
  const models = [0, 1, 2].map((i) => ({ id: String(i), name: String(i), gb: 30 }));
  const map = memoryMap(128, models, 52);
  const weights = map.segments.filter((s) => s.kind === 'weights');
  expect(weights.reduce((sum, s) => sum + s.to - s.from, 0)).toBeCloseTo(52 / 128);
  expect(new Set(models.map((_, i) => modelColor(i).join(','))).size).toBe(3);
});
