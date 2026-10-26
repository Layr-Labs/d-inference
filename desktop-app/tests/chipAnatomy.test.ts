import { describe, expect, it } from 'vitest';
import { chipAnatomy } from '../src/renderer/features/home/chip/anatomy';

describe('chip anatomy', () => {
  it('parses family and tier from the machine chip string', () => {
    expect(chipAnatomy('Apple M4 Max', 64)).toMatchObject({
      name: 'Apple M4 Max',
      family: 'M4',
      generation: 4,
      tier: 'max',
      known: true,
      performanceCores: 12,
      efficiencyCores: 4,
      gpuCores: 40,
      neuralCores: 16,
      dies: 1,
      memoryPackages: 4,
      bandwidthGBs: 546,
      memoryGb: 64,
    });
    expect(chipAnatomy('Apple M1', 16)).toMatchObject({
      tier: 'base',
      gpuCores: 8,
      memoryPackages: 2,
      bandwidthGBs: 68,
    });
    expect(chipAnatomy('Apple M2 Pro', 32)).toMatchObject({ tier: 'pro', gpuCores: 19 });
    expect(chipAnatomy('apple m3 ultra', 192)).toMatchObject({
      family: 'M3',
      tier: 'ultra',
      dies: 2,
      neuralCores: 32,
      memoryPackages: 8,
      gpuCores: 80,
      performanceCores: 24,
    });
  });

  it('extrapolates tiers and generations missing from the table', () => {
    const m4Max = chipAnatomy('Apple M4 Max', 64),
      m5Max = chipAnatomy('Apple M5 Max', 64);
    expect(m5Max).toMatchObject({ known: true, gpuCores: m4Max.gpuCores, memoryPackages: 4 });
    expect(m5Max.bandwidthGBs).toBeGreaterThan(m4Max.bandwidthGBs);
    expect(chipAnatomy('Apple M4 Ultra', 256)).toMatchObject({
      dies: 2,
      gpuCores: 80,
      memoryPackages: 8,
      bandwidthGBs: 1092,
    });
    expect(chipAnatomy('Apple M7 Pro', 48)).toMatchObject({
      family: 'M7',
      tier: 'pro',
      known: true,
      memoryPackages: 2,
    });
  });

  it('falls back to a generic layout named after the raw chip string', () => {
    expect(chipAnatomy('Intel(R) Core(TM) i9', 32)).toMatchObject({
      name: 'Intel(R) Core(TM) i9',
      family: '',
      known: false,
      tier: 'base',
      dies: 1,
      memoryPackages: 2,
    });
    expect(chipAnatomy('  ', Number.NaN)).toMatchObject({ name: 'Apple silicon', memoryGb: 0 });
  });
});
