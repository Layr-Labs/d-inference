import type { NetworkData } from '../src/shared/contracts';

const row = (chip: string, machines: number, median: string, mean: string) => ({
  chip,
  machines,
  median_micro_usd_per_machine_day: median,
  mean_micro_usd_per_machine_day: mean,
});

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
