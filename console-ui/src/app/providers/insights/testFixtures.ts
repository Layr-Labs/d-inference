import type { ProviderInsights } from "./types";

export function makeInsights(overrides: Partial<ProviderInsights> = {}): ProviderInsights {
  const amounts = { work_micro_usd: 200_000, base_reward_micro_usd: 800_000, jobs: 4, prompt_tokens: 1200, completion_tokens: 800 };
  return {
    window: "7d", since: "2026-09-25T00:00:00Z", as_of: "2026-10-01T12:00:00Z",
    lifetime: { count: 1000, total_micro_usd: 19_000_000, prompt_tokens: 5_000_000, completion_tokens: 1_200_000 },
    totals: amounts,
    days: Array.from({ length: 7 }, (_, i) => ({ id: i === 6 ? "2026-10-01" : `2026-09-${25 + i}`, ...amounts })),
    models: [{ id: "qwen-35b", ...amounts, base_reward_micro_usd: 0 }, { id: "base_reward", ...amounts, work_micro_usd: 0, jobs: 0, prompt_tokens: 0, completion_tokens: 0 }],
    machines: [{ id: "mac-one", ...amounts }], ...overrides,
  };
}
