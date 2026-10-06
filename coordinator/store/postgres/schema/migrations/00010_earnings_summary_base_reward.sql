-- +goose Up
-- total_base_reward_micro_usd is the part of total_micro_usd that came from
-- base rewards; BackfillEarningsSummaryBaseReward fills it for history at
-- serving startup. The pending table is its crash-safe work queue.
ALTER TABLE earnings_summary ADD COLUMN IF NOT EXISTS total_base_reward_micro_usd BIGINT NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS earnings_summary_base_reward_pending (
 account_id TEXT PRIMARY KEY,
 amount_micro_usd BIGINT NOT NULL
);
