export interface InsightAmounts {
  work_micro_usd: number;
  base_reward_micro_usd: number;
  jobs: number;
  prompt_tokens: number;
  completion_tokens: number;
}
export interface InsightSlice extends InsightAmounts { id: string }
export interface ProviderInsights {
  window: "7d" | "30d";
  since: string;
  as_of: string;
  lifetime: { count: number; total_micro_usd: number; prompt_tokens: number; completion_tokens: number };
  totals: InsightAmounts;
  days: InsightSlice[];
  models: InsightSlice[];
  machines: InsightSlice[];
}
export const compact = (value: number) => new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(value);
export const money = (micro: number) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: micro !== 0 && Math.abs(micro) < 10_000 ? 6 : 2 }).format(micro / 1_000_000);
export const earned = (value: InsightAmounts) => value.work_micro_usd + value.base_reward_micro_usd;
export const dayLabel = (id: string) => new Date(`${id}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
