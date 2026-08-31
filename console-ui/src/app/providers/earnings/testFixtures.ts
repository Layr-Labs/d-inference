// Shared fixtures for the earnings page. Factories with realistic defaults
// (same pattern as providers/dashboard/testFixtures.ts) plus named scenarios
// the UI must survive. Consumed by the vitest suite and the dev-only
// NEXT_PUBLIC_EARNINGS_FIXTURE preview mode.

import type { StripeStatus } from "@/lib/api";
import type { Earning, EarningsResponse } from "./types";

export function makeStripeStatus(
  overrides: Partial<StripeStatus> = {},
): StripeStatus {
  return {
    configured: true,
    has_account: true,
    status: "ready",
    destination_type: "bank",
    destination_last4: "4821",
    min_withdraw_micro_usd: 1_000_000,
    ...overrides,
  };
}

/** Fixed clock so scenario data is deterministic in tests. */
export const FIXTURE_NOW = new Date("2025-05-30T10:30:00").getTime();

export function makeEarning(overrides: Partial<Earning> = {}): Earning {
  return {
    id: 1,
    provider_id: "prov-a",
    provider_key: "key-a",
    job_id: "job-1",
    model: "Qwen/Qwen3-30B-A3B",
    amount_micro_usd: 84_210,
    prompt_tokens: 322_198,
    completion_tokens: 923_114,
    created_at: new Date(FIXTURE_NOW - 6 * 60_000).toISOString(),
    ...overrides,
  };
}

export function makeEarningsResponse(
  overrides: Partial<EarningsResponse> = {},
): EarningsResponse {
  const earnings = overrides.earnings ?? [makeEarning()];
  const totalMicro =
    overrides.total_micro_usd ??
    earnings.reduce((s, e) => s + e.amount_micro_usd, 0);
  return {
    account_id: "acct-1",
    earnings,
    total_micro_usd: totalMicro,
    total_usd: (totalMicro / 1_000_000).toFixed(6),
    count: earnings.length,
    recent_count: earnings.length,
    history_limit: 100,
    available_balance_micro_usd: 342_180_000,
    available_balance_usd: "342.180000",
    withdrawable_balance_micro_usd: 326_400_000,
    withdrawable_balance_usd: "326.400000",
    ...overrides,
  };
}

const MODELS = [
  "Qwen/Qwen3-30B-A3B",
  "google/gemma-3-27b-it",
  "Qwen/Qwen3-VL-8B",
];
const PROVIDERS = ["prov-a", "prov-b", "prov-c"];

/** ~40 rows spread over ~2 weeks, several models, 3 machines. */
function typicalEarnings(now: number): Earning[] {
  const rows: Earning[] = [];
  for (let i = 0; i < 40; i++) {
    // Deterministic pseudo-spread: walk back through 14 days.
    const ageMs = Math.floor((i * 14 * 86_400_000) / 40) + (i % 7) * 3_600_000;
    const completion = 400_000 + ((i * 97_531) % 600_000);
    rows.push(
      makeEarning({
        id: 1000 - i,
        provider_id: PROVIDERS[i % PROVIDERS.length],
        provider_key: `key-${i % PROVIDERS.length}`,
        job_id: `job-${1000 - i}`,
        model: MODELS[i % MODELS.length],
        amount_micro_usd: 30_000 + ((i * 13_337) % 60_000),
        prompt_tokens: 100_000 + ((i * 31_415) % 300_000),
        completion_tokens: completion,
        created_at: new Date(now - ageMs).toISOString(),
      }),
    );
  }
  return rows;
}

export type ScenarioName =
  | "EMPTY"
  | "TYPICAL"
  | "TRUNCATED"
  | "CREDITS_ONLY"
  | "BELOW_MIN_WITHDRAW"
  | "WHALE";

export function makeScenario(
  name: ScenarioName,
  now: number = FIXTURE_NOW,
): EarningsResponse {
  switch (name) {
    case "EMPTY":
      return makeEarningsResponse({
        earnings: [],
        total_micro_usd: 0,
        total_usd: "0.000000",
        count: 0,
        recent_count: 0,
        available_balance_micro_usd: 0,
        available_balance_usd: "0.000000",
        withdrawable_balance_micro_usd: 0,
        withdrawable_balance_usd: "0.000000",
      });
    case "TYPICAL":
      return makeEarningsResponse({
        earnings: typicalEarnings(now),
        total_micro_usd: 1_284_360_000,
        total_usd: "1284.360000",
        count: 18_742,
        recent_count: 40,
      });
    case "TRUNCATED": {
      const rows = typicalEarnings(now);
      // Pad to a full server page of 100 rows.
      while (rows.length < 100) {
        const i = rows.length;
        rows.push(
          makeEarning({
            id: 100 - i,
            job_id: `job-old-${i}`,
            model: MODELS[i % MODELS.length],
            created_at: new Date(now - 15 * 86_400_000 - i * 3_600_000).toISOString(),
          }),
        );
      }
      return makeEarningsResponse({
        earnings: rows,
        count: 4210,
        recent_count: 100,
      });
    }
    case "CREDITS_ONLY":
      return makeEarningsResponse({
        earnings: typicalEarnings(now).slice(0, 8),
        count: 8,
        recent_count: 8,
        available_balance_micro_usd: 15_780_000,
        available_balance_usd: "15.780000",
        withdrawable_balance_micro_usd: 0,
        withdrawable_balance_usd: "0.000000",
      });
    case "BELOW_MIN_WITHDRAW":
      return makeEarningsResponse({
        earnings: typicalEarnings(now).slice(0, 5),
        count: 5,
        recent_count: 5,
        available_balance_micro_usd: 730_000,
        available_balance_usd: "0.730000",
        withdrawable_balance_micro_usd: 480_000,
        withdrawable_balance_usd: "0.480000",
      });
    case "WHALE":
      return makeEarningsResponse({
        earnings: typicalEarnings(now).map((e, i) => ({
          ...e,
          model:
            i % 2 === 0
              ? "SomeVeryLongOrganizationName/An-Extremely-Long-Model-Identifier-235B-A22B-Instruct-2507"
              : e.model,
          amount_micro_usd: e.amount_micro_usd * 2_000,
          completion_tokens: e.completion_tokens * 40,
          prompt_tokens: e.prompt_tokens * 40,
        })),
        total_micro_usd: 4_812_930_120_000,
        total_usd: "4812930.120000",
        count: 9_812_331,
        recent_count: 40,
        available_balance_micro_usd: 812_412_550_000,
        available_balance_usd: "812412.550000",
        withdrawable_balance_micro_usd: 799_912_550_000,
        withdrawable_balance_usd: "799912.550000",
      });
  }
}
