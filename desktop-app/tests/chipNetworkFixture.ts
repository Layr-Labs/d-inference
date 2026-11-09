import type { NetworkData } from '../src/shared/contracts';

type ModelRow = NonNullable<NetworkData['model_earnings']>['models'][number];

const row = (chip: string, machines: number, median: string, mean: string) => ({
  chip,
  machines,
  median_micro_usd_per_machine_day: median,
  mean_micro_usd_per_machine_day: mean,
});

function mapModels(network: NetworkData, map: (model: ModelRow) => ModelRow): NetworkData {
  const earnings = network.model_earnings!;
  return { model_earnings: { ...earnings, models: earnings.models.map(map) } };
}

// Network totals favor Qwen 3.6 (many fast Macs serve it), while Macs with this fixture's
// chip (Apple M4 Max) earn most from Qwen 3.5 9B and nothing from Qwen 3.6.
export function chipNetwork(): NetworkData {
  return {
    model_earnings: {
      window: '7d',
      as_of: new Date().toISOString(),
      by_chip_window: '24h',
      models: [
        {
          id: 'kimi-k2.6',
          earnings_micro_usd: '9000000',
          by_chip: [row('Apple M5 Ultra', 4, '5000000', '6000000')],
        },
        {
          id: 'qwen-3.6-35b',
          earnings_micro_usd: '4000000',
          by_chip: [row('Apple M5 Max', 9, '900000', '1000000'), row('Apple M4 Max', 5, '0', '0')],
        },
        {
          id: 'qwen-3.5-9b',
          earnings_micro_usd: '3000000',
          by_chip: [row('Apple M4 Max', 6, '120000', '150000')],
        },
        {
          id: 'gpt-oss-20b',
          earnings_micro_usd: '2000000',
          by_chip: [row('Apple M4 Max', 8, '40000', '90000')],
        },
        {
          id: 'gemma-4-26b',
          earnings_micro_usd: '1000000',
          by_chip: [row('Apple M4 Max', 7, '0', '3000')],
        },
      ],
    },
  };
}

// Macs with this fixture's chip have rows only for a model too large for the pool's Mac and for
// one that paid them nothing, so no model this Mac can serve has per-chip earnings.
export function uncoveredChipNetwork(): NetworkData {
  return mapModels(chipNetwork(), (model) => ({
    ...model,
    by_chip:
      model.id === 'kimi-k2.6'
        ? [...model.by_chip!, row('Apple M4 Max', 3, '2000000', '2500000')]
        : model.by_chip!.filter(
            (entry) => entry.chip !== 'Apple M4 Max' || model.id === 'qwen-3.6-35b',
          ),
  }));
}

// The typical and the average Mac of this chip disagree: Qwen 3.5 9B pays the median Mac more
// ($0.05 a day against $0.04), while a few busy Macs lift GPT-OSS 20B's mean to $0.20.
export function skewedChipNetwork(): NetworkData {
  const skewed: Record<string, ReturnType<typeof row>> = {
    'qwen-3.5-9b': row('Apple M4 Max', 6, '50000', '60000'),
    'gpt-oss-20b': row('Apple M4 Max', 8, '40000', '200000'),
  };
  return mapModels(chipNetwork(), (model) =>
    skewed[model.id] ? { ...model, by_chip: [skewed[model.id]] } : model,
  );
}

// Partial data: Gemma's row has no by_chip (the coordinator omits it when none of the model's
// chip classes reaches its publication floor), beside rows that have one.
export function partialChipNetwork(): NetworkData {
  return mapModels(chipNetwork(), ({ by_chip, ...model }) =>
    model.id === 'gemma-4-26b' ? model : { ...model, by_chip },
  );
}
