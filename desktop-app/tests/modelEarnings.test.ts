import { describe, expect, it } from 'vitest';
import { rankModels, modelEarnings } from '../src/renderer/features/models/earnings';
import { parseInsights } from '../src/renderer/features/insights/types';
import { previewInsights } from '../src/renderer/previewInsights';
import { poolModels } from './modelsFixtures';

describe('models ranked by settled earnings', () => {
  it('sorts descending with exact counters and preserves ties without mutating selection order', () => {
    const earnings = new Map([
      ['gpt-oss-20b', 9007199254740992n],
      ['gemma-4-26b', 9007199254740993n],
      ['qwen-3.5-9b', 0n],
    ]);
    expect(rankModels(poolModels, earnings).map((model) => model.id)).toEqual([
      'gemma-4-26b',
      'gpt-oss-20b',
      'qwen-3.5-9b',
      'qwen-3.6-35b',
      'kimi-k2.6',
    ]);
    expect(poolModels[0].id).toBe('gpt-oss-20b');
  });
  it('keeps catalog order when earnings have never been supplied', () => {
    expect(modelEarnings(null)).toBeNull();
    expect(rankModels(poolModels, null)).toBe(poolModels);
  });
  it('uses only model-attributed settled earnings', () => {
    const insights = parseInsights(previewInsights('30d'));
    const row = insights.models[0];
    insights.models.push({ ...row, id: '', work_micro_usd: 999999999n });
    const earnings = modelEarnings(insights)!;
    expect(earnings.get(row.id)).toBe(row.work_micro_usd + row.base_reward_micro_usd);
    expect(earnings.has('')).toBe(false);
  });
});
