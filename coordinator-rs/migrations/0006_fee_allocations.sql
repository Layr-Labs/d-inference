-- 0006_fee_allocations.sql
--
-- rust_coord.fee_allocations — insert-only authoritative platform-fee and
-- referral-reward rows (plan §12.6). Settlement inserts them synchronously in
-- the settlement transaction, but does NOT update the materialized platform /
-- referrer balances synchronously: that would serialize every settlement on
-- one global platform account row. A bounded single-writer projection folds
-- unprojected rows into the materialized balances and their legacy
-- compatibility projections; §26.3 reconciliation sums these rows as the
-- financial authority; rollback quiescence (§26.1) requires projected = TRUE
-- for every row.
--
-- Timeouts: bounded per plan §20; new empty table only.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE rust_coord.fee_allocations (
	id BIGSERIAL PRIMARY KEY,
	job_id UUID NOT NULL REFERENCES rust_coord.inference_jobs (job_id),
	beneficiary_account_id TEXT NOT NULL,
	kind TEXT NOT NULL CHECK (kind IN ('platform', 'referral')),
	amount_micro_usd BIGINT NOT NULL CHECK (amount_micro_usd >= 0),
	-- Flipped to TRUE by the single-writer projection after the amount is
	-- folded into the materialized balance + legacy ledger projection.
	projected BOOLEAN NOT NULL DEFAULT FALSE,
	projected_at TIMESTAMPTZ,
	coordinator_epoch BIGINT NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

	-- Settlement computes at most one platform and one referral allocation
	-- per job from the frozen terms; re-settlement of the same job must not
	-- duplicate them.
	UNIQUE (job_id, kind)
);
COMMENT ON TABLE rust_coord.fee_allocations IS
	'Plan §12.6: insert-only authoritative platform/referral fee rows; a bounded single-writer projection folds them into materialized balances; §26.3 sums them.';

-- The fee-projection worker's scan set: unprojected rows, oldest first.
-- Rollback quiescence (§26.1) polls this to zero.
CREATE INDEX idx_rust_fee_alloc_unprojected
	ON rust_coord.fee_allocations (created_at)
	WHERE NOT projected;

CREATE INDEX idx_rust_fee_alloc_beneficiary
	ON rust_coord.fee_allocations (beneficiary_account_id, created_at DESC);

UPDATE rust_coord.schema_meta
SET schema_version = 6, updated_at = NOW()
WHERE id = 1;
