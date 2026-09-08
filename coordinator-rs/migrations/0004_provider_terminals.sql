-- 0004_provider_terminals.sql
--
-- rust_coord.provider_terminals — idempotent signed terminal receipts and
-- their financial disposition (plan §12.1, §10.6, §12.8).
--
-- Timeouts: bounded per plan §20; new empty table only.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE rust_coord.provider_terminals (
	attempt_id UUID NOT NULL REFERENCES rust_coord.inference_attempts (attempt_id),
	-- Digest of the canonical signed terminal. Duplicate delivery of the SAME
	-- (attempt_id, terminal_digest) upserts received_count and replays the
	-- stored disposition (plan §12.8). The SAME attempt with a DIFFERENT
	-- digest is insertable as a second row but is a protocol conflict: the
	-- settlement layer marks conflict = TRUE on every row of the attempt,
	-- quarantines the provider, and moves no money (plan §10.6, §18
	-- "Terminal conflict").
	terminal_digest BYTEA NOT NULL,

	-- Plan §10.6: full canonical signed terminal as received (IDs, outcome,
	-- usage, digests, signature — never prompt or response content), plus
	-- extracted columns settlement verifies against the frozen job terms.
	raw_terminal JSONB NOT NULL,
	outcome TEXT NOT NULL,
	error_class TEXT,
	prompt_tokens BIGINT NOT NULL CHECK (prompt_tokens >= 0),
	completion_tokens BIGINT NOT NULL CHECK (completion_tokens >= 0),
	reasoning_tokens BIGINT NOT NULL DEFAULT 0 CHECK (reasoning_tokens >= 0),
	response_hash BYTEA NOT NULL,
	-- Provider-side final generated-token count and rolling-hash checkpoint;
	-- settlement joins these with the coordinator's independent
	-- accepted-chunk checkpoint on the job (plan §10.6).
	final_generated_tokens BIGINT NOT NULL CHECK (final_generated_tokens >= 0),
	rolling_hash_checkpoint BYTEA,
	provider_signature BYTEA NOT NULL,
	-- Plan §9.1.3: historical terminal replay references its ORIGIN session
	-- epoch, authenticated as the same stable provider.
	origin_session_epoch BIGINT NOT NULL,

	coordinator_epoch BIGINT NOT NULL,

	-- Financial disposition of this receipt: how settlement resolved it.
	-- NULL until the settlement/release reducer runs; 'late' records a
	-- terminal that arrived after release and moved no money (plan §12.7).
	disposition TEXT CHECK (disposition IN (
		'settled', 'duplicate', 'late', 'conflict', 'review_pending', 'rejected'
	)),
	disposition_at TIMESTAMPTZ,
	conflict BOOLEAN NOT NULL DEFAULT FALSE,
	received_count INTEGER NOT NULL DEFAULT 1 CHECK (received_count >= 1),

	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

	PRIMARY KEY (attempt_id, terminal_digest)
);
COMMENT ON TABLE rust_coord.provider_terminals IS
	'Plan §12.1/§10.6/§12.8: idempotent signed provider terminal receipts; duplicates replay disposition, digest conflicts quarantine.';

-- Recovery sweeper (plan §18.1): terminal receipts awaiting settlement.
CREATE INDEX idx_rust_terminals_awaiting_settlement
	ON rust_coord.provider_terminals (created_at)
	WHERE disposition IS NULL;

-- Conflict quarantine review (plan §18 "Terminal conflict").
CREATE INDEX idx_rust_terminals_conflict
	ON rust_coord.provider_terminals (created_at)
	WHERE conflict;

UPDATE rust_coord.schema_meta
SET schema_version = 4, updated_at = NOW()
WHERE id = 1;
