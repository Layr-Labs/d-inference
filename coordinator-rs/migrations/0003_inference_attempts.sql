-- 0003_inference_attempts.sql
--
-- rust_coord.inference_attempts — one row per provider dispatch: attempt
-- identity, provider/session/lease binding, request digest, and attempt state
-- (plan §12.1, §12.2, §10.2).
--
-- Timeouts: bounded per plan §20; new empty table only.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE rust_coord.inference_attempts (
	attempt_id UUID PRIMARY KEY,
	job_id UUID NOT NULL REFERENCES rust_coord.inference_jobs (job_id),

	-- Plan §10.2 identifiers: every frame carries these; the provider compares
	-- the inner (encrypted) and outer values after decryption.
	provider_stable_id TEXT NOT NULL,
	session_epoch BIGINT NOT NULL,
	coordinator_epoch BIGINT NOT NULL,
	lease_id UUID,
	dispatch_nonce BYTEA NOT NULL,
	request_digest BYTEA NOT NULL,

	-- Plan §12.2 attempt states. sent_unknown is explicit because a socket
	-- error cannot prove whether the provider received the request.
	state TEXT NOT NULL DEFAULT 'queued_to_socket' CHECK (state IN (
		'queued_to_socket', 'sent_unknown', 'prepared', 'started',
		'terminal_recorded', 'aborted', 'acknowledged'
	)),

	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

	-- A prepared lease and everything past it must reference the lease.
	CHECK (state NOT IN ('prepared', 'started') OR lease_id IS NOT NULL)
);
COMMENT ON TABLE rust_coord.inference_attempts IS
	'Plan §12.1/§12.2: one provider dispatch — identity, provider/session/lease binding, request digest, state.';

-- Invariant 9.2.3: at most one attempt per job is ever funded and
-- start-authorized. The states 'started', 'terminal_recorded', and
-- 'acknowledged' are reachable only THROUGH start authorization, so a partial
-- unique index on job_id over those states makes a second funded start a
-- constraint violation, not a code-review promise. 'aborted' is deliberately
-- excluded: an abort tombstone before start never consumed the single start
-- authorization, and a started attempt that is cancelled still terminates
-- through terminal_recorded (plan §10.3: "If start wins first, a later abort
-- becomes cancellation of the running attempt and must produce a terminal").
-- Multiple 'prepared' attempts are allowed (one primary + one prepare hedge,
-- plan §9.2.3); prepared leases emit nothing, and the funding
-- compare-and-swap selects the single start.
CREATE UNIQUE INDEX idx_rust_attempts_one_started_per_job
	ON rust_coord.inference_attempts (job_id)
	WHERE state IN ('started', 'terminal_recorded', 'acknowledged');

-- All attempts of a job, newest first (RequestTask recovery, reconciliation).
CREATE INDEX idx_rust_attempts_job
	ON rust_coord.inference_attempts (job_id, created_at DESC);

-- Recovery sweeper (plan §18.1): non-terminal attempts by provider, so
-- session teardown and lease-expiry sweeps never scan acknowledged history.
CREATE INDEX idx_rust_attempts_live_by_provider
	ON rust_coord.inference_attempts (provider_stable_id, updated_at)
	WHERE state IN ('queued_to_socket', 'sent_unknown', 'prepared', 'started');

UPDATE rust_coord.schema_meta
SET schema_version = 3, updated_at = NOW()
WHERE id = 1;
