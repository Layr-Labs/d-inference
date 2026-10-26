import { describe, expect, it } from 'vitest';
import type { NetworkData } from '../src/shared/contracts';
import {
  chipEarnings,
  networkEarnings,
  recommendedModels,
} from '../src/renderer/features/models/recommendations';
import { poolModels } from './modelsFixtures';
import { chipNetwork } from './chipNetworkFixture';

describe('recommendations from Macs with the same chip', () => {
  it('reads what Macs with this chip earned per model and ignores other chips', () => {
    const earnings = chipEarnings(chipNetwork(), 'Apple M4 Max');
    expect(earnings && Object.fromEntries(earnings)).toEqual({
      'qwen-3.6-35b': { median: 0n, mean: 0n },
      'qwen-3.5-9b': { median: 120000n, mean: 150000n },
      'gpt-oss-20b': { median: 40000n, mean: 90000n },
      'gemma-4-26b': { median: 0n, mean: 3000n },
    });
    expect(chipEarnings(chipNetwork(), 'Apple M2 Pro')).toBeNull();
    expect(chipEarnings(chipNetwork(), undefined)).toBeNull();
  });

  it('ranks by the typical then the average Mac of this chip, not by network totals', () => {
    const network = chipNetwork();
    const totals = networkEarnings(network);
    expect(recommendedModels(poolModels, totals).map((m) => m.id)).toEqual([
      'qwen-3.6-35b',
      'qwen-3.5-9b',
      'gpt-oss-20b',
    ]);
    // Qwen 3.6 paid these Macs nothing and the Kimi class is another chip (and too large here).
    expect(
      recommendedModels(poolModels, totals, chipEarnings(network, 'Apple M4 Max')).map((m) => m.id),
    ).toEqual(['qwen-3.5-9b', 'gpt-oss-20b', 'gemma-4-26b']);
  });

  it('falls back to network totals when per-chip data is absent, stale or malformed', () => {
    const network = chipNetwork();
    const earnings = network.model_earnings!;
    const without = (patch: Partial<typeof earnings>): NetworkData => ({
      model_earnings: { ...earnings, ...patch },
    });
    expect(chipEarnings(without({ by_chip_window: undefined }), 'Apple M4 Max')).toBeNull();
    expect(
      chipEarnings(
        without({ as_of: new Date(Date.now() - 6 * 60_000).toISOString() }),
        'Apple M4 Max',
      ),
    ).toBeNull();
    for (const bad of [
      { chip: 'Apple M4 Max', machines: 0, median: '1', mean: '1' },
      { chip: 'Apple M4 Max', machines: 3, median: '-1', mean: '1' },
      { chip: 'Apple M4 Max', machines: 3, median: '1', mean: '1.5' },
      { chip: 7, machines: 3, median: '1', mean: '1' },
    ])
      expect(
        chipEarnings(
          without({
            models: [
              {
                id: 'gpt-oss-20b',
                earnings_micro_usd: '1',
                by_chip: [
                  {
                    chip: bad.chip as string,
                    machines: bad.machines,
                    median_micro_usd_per_machine_day: bad.median,
                    mean_micro_usd_per_machine_day: bad.mean,
                  },
                ],
              },
            ],
          }),
          'Apple M4 Max',
        ),
      ).toBeNull();
    // Without per-chip data the existing network-total ranking is unchanged.
    expect(recommendedModels(poolModels, networkEarnings(network), null).map((m) => m.id)).toEqual([
      'qwen-3.6-35b',
      'qwen-3.5-9b',
      'gpt-oss-20b',
    ]);
  });
});
