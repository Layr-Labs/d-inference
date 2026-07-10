-- 0005_financial_operations.sql
--
-- rust_coord.financial_operations — THE idempotency table (plan §9.3.2,
-- §12.5): every money-moving command carries an immutable operation key. If
-- PostgreSQL returns an ambiguous commit result, the caller reconnects and
-- queries this key before retrying; a debit or credit is never replayed just
-- because the commit response was lost.
--
-- Timeouts: bounded per plan §20; new empty table only.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE rust_coord.financial_operations (
	operation_key TEXT PRIMARY KEY,
	kind TEXT NOT NULL CHECK (kind IN (
		'reserve', 'resize', 'settle', 'release', 'deposit',
		'withdrawal_intent', 'fee_projection'
	)),
	-- NULL for job-less operations (deposit, withdrawal_intent).
	job_id UUID REFERENCES rust_coord.inference_jobs (job_id),
	account_id TEXT NOT NULL,

	-- Signed micro-USD deltas this operation applied to the account's legacy
	-- balance projection (negative = debit). Recorded so ambiguous-commit
	-- recovery and §26.3 reconciliation can verify the exact effect without
	-- re-deriving it.
	amount_total_micro_usd BIGINT NOT NULL,
	amount_withdrawable_micro_usd BIGINT NOT NULL,

	-- Full structured result returned to the caller on first execution;
	-- replayed verbatim for a retried key.
	result JSONB NOT NULL DEFAULT '{}'::jsonb,

	coordinator_epoch BIGINT NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE rust_coord.financial_operations IS
	'Plan §9.3.2/§12.5: unique operation keys for reserve/resize/settle/release/deposit/withdrawal_intent/fee_projection; ambiguous-commit recovery queries by key.';

-- One kind of operation happens at most a handful of times per job;
-- reconciliation (§26.3) walks a job's full financial history through this.
CREATE INDEX idx_rust_finops_job
	ON rust_coord.financial_operations (job_id, created_at)
	WHERE job_id IS NOT NULL;

CREATE INDEX idx_rust_finops_account
	ON rust_coord.financial_operations (account_id, created_at DESC);

UPDATE rust_coord.schema_meta
SET schema_version = 5, updated_at = NOW()
WHERE id = 1;
