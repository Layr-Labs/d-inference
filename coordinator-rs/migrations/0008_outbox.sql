-- 0008_outbox.sql
--
-- rust_coord.outbox — non-critical side effects, notifications, and
-- projections (plan §12.1, §12.6): fee-projection ticks, analytics rows,
-- telemetry fan-out. Rows here may retry and eventually dead-letter; they
-- never carry money authority (fee amounts live in rust_coord.fee_allocations,
-- balances in the legacy projections, idempotency in financial_operations).
--
-- Timeouts: bounded per plan §20; new empty table only.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE rust_coord.outbox (
	id BIGSERIAL PRIMARY KEY,
	kind TEXT NOT NULL,
	payload JSONB NOT NULL DEFAULT '{}'::jsonb,
	state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'done', 'dead')),
	attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
	next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	coordinator_epoch BIGINT NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE rust_coord.outbox IS
	'Plan §12.1/§12.6: bounded retry outbox for non-critical side effects and projections; carries no money authority.';

-- Recovery sweeper (plan §18.1): external outbox retries. Workers claim due
-- pending rows with FOR UPDATE SKIP LOCKED ordered by next_attempt_at.
CREATE INDEX idx_rust_outbox_pending
	ON rust_coord.outbox (next_attempt_at)
	WHERE state = 'pending';

-- Dead-letter review.
CREATE INDEX idx_rust_outbox_dead
	ON rust_coord.outbox (created_at)
	WHERE state = 'dead';

UPDATE rust_coord.schema_meta
SET schema_version = 8, updated_at = NOW()
WHERE id = 1;
