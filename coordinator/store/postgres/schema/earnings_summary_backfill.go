package schema

const EarningsSummaryBackfillPendingDDL = `CREATE TABLE IF NOT EXISTS earnings_summary_backfill_pending (
 key TEXT NOT NULL, key_type TEXT NOT NULL,
 total_count BIGINT NOT NULL, total_micro_usd BIGINT NOT NULL,
 total_prompt_tokens BIGINT NOT NULL, total_completion_tokens BIGINT NOT NULL,
 PRIMARY KEY (key, key_type)
)`
