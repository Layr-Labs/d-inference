-- Financial operation parameter binding (DECISIONS #34/#138).
-- Additive only — mirrors MemoryLedger OperationRecord so reused op keys
-- with mismatched account/job/amount/digest/cap cannot silently no-op.

ALTER TABLE rust_coord.financial_operations
    ADD COLUMN IF NOT EXISTS account_id TEXT NOT NULL DEFAULT '';

ALTER TABLE rust_coord.financial_operations
    ADD COLUMN IF NOT EXISTS terminal_digest TEXT NOT NULL DEFAULT '';

ALTER TABLE rust_coord.financial_operations
    ADD COLUMN IF NOT EXISTS billable_cap_micro_usd BIGINT;

CREATE INDEX IF NOT EXISTS idx_rust_financial_ops_account
    ON rust_coord.financial_operations(account_id);
