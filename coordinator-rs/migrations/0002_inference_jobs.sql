-- 0002_inference_jobs.sql
--
-- rust_coord.inference_jobs — one row per logical consumer request: durable
-- money state machine, reservation provenance, frozen pricing/beneficiary
-- terms, deadlines, and terminal disposition (plan §12.1, §12.2, §12.3, §12.4).
--
-- Timeouts: bounded per plan §20; new empty table only, never waits on
-- production traffic.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE rust_coord.inference_jobs (
	job_id UUID PRIMARY KEY,
	account_id TEXT NOT NULL,
	api_key_id TEXT NOT NULL DEFAULT '',

	-- Plan §20: fencing epoch of the coordinator that created the job. Every
	-- authoritative mutation compares the expected active epoch in the same
	-- transaction; zero affected rows means immediate ownership loss.
	coordinator_epoch BIGINT NOT NULL,

	-- Plan §12.2 durable job states. settled / released / settled_reviewed /
	-- released_reviewed are terminal money states; review_pending is
	-- nonterminal, keeps its reservation debited, and blocks Go rollback.
	state TEXT NOT NULL DEFAULT 'reserved' CHECK (state IN (
		'reserved', 'preparing', 'prepared', 'start_authorized', 'running',
		'settled', 'released', 'review_pending', 'settled_reviewed',
		'released_reviewed'
	)),

	-- Plan §7.2: optimistic-concurrency column. Every live and recovery
	-- mutation CASes the expected version (WHERE version = $expected) and
	-- increments it; the versioned job reducer in PostgreSQL is the sole
	-- durable terminal authority.
	version BIGINT NOT NULL DEFAULT 1,

	-- Reserve idempotency (plan §9.3.2, §12.5): the job-level operation key.
	-- A retried reserve with the same key finds this row instead of debiting
	-- twice. Also recorded in rust_coord.financial_operations.
	reserve_operation_key TEXT NOT NULL UNIQUE,

	-- Plan §12.3 reservation provenance, micro-USD. The reservation debits
	-- the legacy balance by reserved_total and the legacy withdrawable subset
	-- by reserved_withdrawable (nonwithdrawable funds are consumed first).
	-- Release and settlement refund BOTH components exactly.
	reserved_total_micro_usd BIGINT NOT NULL CHECK (reserved_total_micro_usd >= 0),
	reserved_withdrawable_micro_usd BIGINT NOT NULL CHECK (reserved_withdrawable_micro_usd >= 0),

	-- Plan §12.4 frozen pricing/beneficiary terms. NULL until the resize
	-- transaction freezes them; the CHECK below forbids start authorization
	-- with unfrozen terms. No settlement path may re-read mutable pricing,
	-- user role, provider ownership, or referral rules.
	concrete_model TEXT,
	public_model TEXT,
	pricing_version BIGINT,
	rounding_version BIGINT,
	billable_input_tokens BIGINT CHECK (billable_input_tokens >= 0),
	bounded_output_tokens BIGINT CHECK (bounded_output_tokens >= 0),
	provider_stable_id TEXT,
	beneficiary_account_id TEXT,
	provider_payout_micro_usd BIGINT CHECK (provider_payout_micro_usd >= 0),
	platform_fee_micro_usd BIGINT CHECK (platform_fee_micro_usd >= 0),
	referral_beneficiary_account_id TEXT,
	referral_share_ppm BIGINT CHECK (referral_share_ppm BETWEEN 0 AND 1000000),
	request_digest BYTEA,

	-- Absolute deadlines shared by every attempt; they never reset on
	-- failover (plan §9.2.5).
	first_content_deadline TIMESTAMPTZ,
	request_deadline TIMESTAMPTZ,

	-- Terminal disposition, written by the settle/release/review reducer.
	outcome TEXT,
	error_class TEXT,
	usage_prompt_tokens BIGINT CHECK (usage_prompt_tokens >= 0),
	usage_completion_tokens BIGINT CHECK (usage_completion_tokens >= 0),
	usage_reasoning_tokens BIGINT CHECK (usage_reasoning_tokens >= 0),
	response_hash BYTEA,
	-- Coordinator-side billable-output linearization point (plan §10.6): the
	-- latest chunk sequence accepted into the bounded consumer pipe and its
	-- cumulative completion-token count. Settlement joins these against the
	-- provider terminal; a mismatch cannot increase consumer charge.
	accepted_chunk_seq BIGINT CHECK (accepted_chunk_seq >= 0),
	accepted_cumulative_tokens BIGINT CHECK (accepted_cumulative_tokens >= 0),

	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

	-- Plan §12.3: withdrawable provenance is a subset of the total.
	CHECK (reserved_withdrawable_micro_usd <= reserved_total_micro_usd),

	-- Plan §12.4 / §9.3.7: a job cannot be start-authorized (or in any state
	-- reached only through start authorization) with unfrozen terms.
	CHECK (
		state NOT IN ('start_authorized', 'running', 'settled')
		OR (
			concrete_model IS NOT NULL
			AND public_model IS NOT NULL
			AND pricing_version IS NOT NULL
			AND rounding_version IS NOT NULL
			AND billable_input_tokens IS NOT NULL
			AND bounded_output_tokens IS NOT NULL
			AND provider_stable_id IS NOT NULL
			AND beneficiary_account_id IS NOT NULL
			AND provider_payout_micro_usd IS NOT NULL
			AND platform_fee_micro_usd IS NOT NULL
			AND request_digest IS NOT NULL
		)
	)
);
COMMENT ON TABLE rust_coord.inference_jobs IS
	'Plan §12.1/§12.2/§12.3/§12.4: durable logical request — money state machine, reservation provenance, frozen terms, deadlines, terminal disposition.';

-- Recovery sweepers (plan §18.1) scan small hot subsets with
-- FOR UPDATE SKIP LOCKED; each gets a dedicated partial index so the scan
-- never touches settled history.
-- Reserved jobs never dispatched.
CREATE INDEX idx_rust_jobs_sweep_reserved
	ON rust_coord.inference_jobs (created_at)
	WHERE state = 'reserved';
-- Prepared jobs never start-authorized (covers the preparing hop too).
CREATE INDEX idx_rust_jobs_sweep_prepared
	ON rust_coord.inference_jobs (updated_at)
	WHERE state IN ('preparing', 'prepared');
-- Start-authorized jobs whose start delivery is unknown: resend the same
-- idempotent start while its exact lease remains valid (plan §18, §9.2.11).
CREATE INDEX idx_rust_jobs_sweep_start_authorized
	ON rust_coord.inference_jobs (updated_at)
	WHERE state = 'start_authorized';
-- Running jobs awaiting terminal replay.
CREATE INDEX idx_rust_jobs_sweep_running
	ON rust_coord.inference_jobs (updated_at)
	WHERE state = 'running';
-- review_pending blocks rollback (plan §26.1 step 5) and is scanned by the
-- reconciler and the quiescence endpoint.
CREATE INDEX idx_rust_jobs_sweep_review_pending
	ON rust_coord.inference_jobs (created_at)
	WHERE state = 'review_pending';

-- Plan §12.5: the reserve transaction enforces per-account/per-key spend caps
-- against settled spend plus ACTIVE Rust reservations in one statement; these
-- partial indexes keep that sum bounded to live rows.
CREATE INDEX idx_rust_jobs_active_by_account
	ON rust_coord.inference_jobs (account_id)
	WHERE state IN ('reserved', 'preparing', 'prepared', 'start_authorized', 'running', 'review_pending');
CREATE INDEX idx_rust_jobs_active_by_api_key
	ON rust_coord.inference_jobs (api_key_id)
	WHERE state IN ('reserved', 'preparing', 'prepared', 'start_authorized', 'running', 'review_pending')
	AND api_key_id <> '';

UPDATE rust_coord.schema_meta
SET schema_version = 2, updated_at = NOW()
WHERE id = 1;
