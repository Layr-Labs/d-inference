// Development fixture only; imported solely by the explicit preview backend.
export function previewInsights(window: '7d' | '30d') {
  const length = window === '7d' ? 7 : 30;
  const days = Array.from({ length }, (_, i) => {
    const date = new Date();
    date.setUTCDate(date.getUTCDate() - (length - 1) + i);
    return {
      id: date.toISOString().slice(0, 10),
      work_micro_usd: String(
        [4200000, 5700000, 3100000, 6500000, 7900000, 6300000, 4600000][i % 7],
      ),
      base_reward_micro_usd: '800000',
      jobs: String(800 + i * 16),
      prompt_tokens: String(1800000 + i * 10000),
      completion_tokens: String(400000 + i * 5000),
    };
  });
  const totals = {
    work_micro_usd: '0',
    base_reward_micro_usd: '0',
    jobs: '0',
    prompt_tokens: '0',
    completion_tokens: '0',
  };
  for (const key of Object.keys(totals) as (keyof typeof totals)[])
    totals[key] = String(days.reduce((sum, day) => sum + Number(day[key]), 0));
  const models = ['gpt-oss-20b', 'gemma-4-26b', 'qwen-3.5-9b'].map((id, index) => {
    const share = [0.6, 0.3, 0.1][index];
    return {
      id,
      work_micro_usd: String(Math.round(Number(totals.work_micro_usd) * share)),
      base_reward_micro_usd: '0',
      jobs: String(Math.round(Number(totals.jobs) * share)),
      prompt_tokens: String(Math.round(Number(totals.prompt_tokens) * share)),
      completion_tokens: String(Math.round(Number(totals.completion_tokens) * share)),
    };
  });
  models.push({
    id: 'base_reward',
    ...totals,
    work_micro_usd: '0',
    jobs: '0',
    prompt_tokens: '0',
    completion_tokens: '0',
  });
  return {
    account_id: 'preview',
    window,
    since: `${days[0].id}T00:00:00Z`,
    as_of: new Date().toISOString(),
    lifetime: {
      count: '120300',
      total_micro_usd: '2146200000',
      prompt_tokens: '340000000',
      completion_tokens: '74821090',
    },
    totals,
    days,
    models,
    machines: models.map((row, i) => ({ ...row, id: i === 3 ? '' : `studio-${i + 1}` })),
  };
}
