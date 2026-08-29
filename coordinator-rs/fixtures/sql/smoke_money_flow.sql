-- smoke_money_flow.sql
--
-- TEST-ONLY regression smoke for the rust_coord money design (plan §12).
-- Run against an ephemeral database, AFTER legacy_baseline.sql and AFTER all
-- coordinator-rs/migrations, with psql -v ON_ERROR_STOP=1. Never run in
-- production.
--
-- Flow exercised (all amounts micro-USD):
--   seed     consumer deposit 6,000,000 (total only) + admin_reward 4,000,000
--            (withdrawable) -> balance 10,000,000 / withdrawable 4,000,000
--   job1     reserve 7,000,000  (withdrawable component = max(0, 7M-6M) = 1M)
--            reserve REPLAY with the same operation key -> no double debit
--            prepare -> resize to 5,000,000 + freeze terms + start_authorized
--            (withdrawable component recomputed to 0, 1M restored)
--            second started attempt -> unique_violation (invariant 9.2.3)
--            terminal (dup digest replay -> received_count = 2)
--            settle: cost 4,000,000 = payout 3,400,000 + platform 500,000
--            + referral 100,000; refund 1,000,000
--   job2     reserve 4,000,000 (withdrawable component = max(0, 4M-2M) = 2M)
--            release restores exactly; late terminal recorded, moves nothing;
--            conflicting second digest for the same attempt flagged
--   projection  fee_allocations folded into platform/referrer balances
--   asserts  §9.3 sums, provenance, ledger consistency, quiescence
BEGIN;

-- Simulate ownership acquisition: all mutations below record epoch 1.
UPDATE rust_coord.coordinator_ownership
SET fencing_epoch = 1, holder = 'smoke-test', acquired_at = NOW(), renewed_at = NOW()
WHERE id = 1;

-- ---------------------------------------------------------------------------
-- Seed: consumer funds. Deposit credits total only; admin_reward credits
-- total + withdrawable (plan §12.11 credit semantics).
-- ---------------------------------------------------------------------------
INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd)
VALUES ('acct_consumer', 6000000, 0);
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
VALUES ('acct_consumer', 'deposit', 6000000, 6000000, 'seed_deposit');

UPDATE balances
SET balance_micro_usd = balance_micro_usd + 4000000,
    withdrawable_micro_usd = withdrawable_micro_usd + 4000000,
    updated_at = NOW()
WHERE account_id = 'acct_consumer';
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
VALUES ('acct_consumer', 'admin_reward', 4000000, 10000000, 'seed_reward');

-- ---------------------------------------------------------------------------
-- Job 1 reserve (plan §12.5): ONE statement of data-modifying CTEs, keyed on
-- the operation key. The financial_operations insert is the idempotency
-- gate: every other CTE selects from it, so a replayed key does nothing.
-- Withdrawable provenance (plan §12.3): nonwithdrawable = 10M - 4M = 6M,
-- reserved_withdrawable = max(0, 7M - 6M) = 1M.
-- ---------------------------------------------------------------------------
WITH op AS (
	INSERT INTO rust_coord.financial_operations
		(operation_key, kind, job_id, account_id,
		 amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
	VALUES
		('op.reserve.job1', 'reserve', '11111111-1111-1111-1111-111111111111', 'acct_consumer',
		 -7000000, -1000000, '{"state":"reserved"}'::jsonb, 1)
	ON CONFLICT (operation_key) DO NOTHING
	RETURNING operation_key
), debit AS (
	UPDATE balances b
	SET balance_micro_usd = b.balance_micro_usd - 7000000,
	    withdrawable_micro_usd = b.withdrawable_micro_usd
	        - GREATEST(0, 7000000 - (b.balance_micro_usd - b.withdrawable_micro_usd)),
	    updated_at = NOW()
	FROM op
	WHERE b.account_id = 'acct_consumer'
	  AND b.balance_micro_usd >= 7000000
	RETURNING b.balance_micro_usd
), job AS (
	INSERT INTO rust_coord.inference_jobs
		(job_id, account_id, api_key_id, coordinator_epoch, state, version,
		 reserve_operation_key,
		 reserved_total_micro_usd, reserved_withdrawable_micro_usd,
		 first_content_deadline, request_deadline)
	SELECT
		'11111111-1111-1111-1111-111111111111', 'acct_consumer', 'key_smoke1', 1, 'reserved', 1,
		'op.reserve.job1',
		7000000, 1000000,
		NOW() + INTERVAL '30 seconds', NOW() + INTERVAL '120 seconds'
	FROM debit
)
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
SELECT 'acct_consumer', 'charge', -7000000, debit.balance_micro_usd,
	'11111111-1111-1111-1111-111111111111'
FROM debit;

-- Replay the SAME reserve (lost commit response, plan §12.5): the operation
-- key conflicts, every dependent CTE sees zero rows, nothing moves.
WITH op AS (
	INSERT INTO rust_coord.financial_operations
		(operation_key, kind, job_id, account_id,
		 amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
	VALUES
		('op.reserve.job1', 'reserve', '11111111-1111-1111-1111-111111111111', 'acct_consumer',
		 -7000000, -1000000, '{"state":"reserved"}'::jsonb, 1)
	ON CONFLICT (operation_key) DO NOTHING
	RETURNING operation_key
), debit AS (
	UPDATE balances b
	SET balance_micro_usd = b.balance_micro_usd - 7000000,
	    withdrawable_micro_usd = b.withdrawable_micro_usd
	        - GREATEST(0, 7000000 - (b.balance_micro_usd - b.withdrawable_micro_usd)),
	    updated_at = NOW()
	FROM op
	WHERE b.account_id = 'acct_consumer'
	  AND b.balance_micro_usd >= 7000000
	RETURNING b.balance_micro_usd
)
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
SELECT 'acct_consumer', 'charge', -7000000, debit.balance_micro_usd,
	'11111111-1111-1111-1111-111111111111'
FROM debit;

DO $$
DECLARE
	bal BIGINT;
	wd BIGINT;
BEGIN
	SELECT balance_micro_usd, withdrawable_micro_usd INTO bal, wd
	FROM balances WHERE account_id = 'acct_consumer';
	ASSERT bal = 3000000, format('reserve idempotency: balance %s, want 3000000', bal);
	ASSERT wd = 3000000, format('reserve provenance: withdrawable %s, want 3000000', wd);
	ASSERT (SELECT COUNT(*) FROM rust_coord.inference_jobs) = 1, 'reserve replay must not duplicate job';
	RAISE NOTICE 'PASS reserve: debit once (balance 3000000, withdrawable 3000000), replay was a no-op';
END $$;

-- ---------------------------------------------------------------------------
-- Job 1 attempt: dispatch -> prepared lease. Job version CASes 1->2->3.
-- ---------------------------------------------------------------------------
INSERT INTO rust_coord.inference_attempts
	(attempt_id, job_id, provider_stable_id, session_epoch, coordinator_epoch,
	 dispatch_nonce, request_digest, state)
VALUES
	('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
	 'prov_1', 7, 1, '\x6e6f6e636531', '\xd1600001', 'queued_to_socket');

DO $$
DECLARE
	n INTEGER;
BEGIN
	UPDATE rust_coord.inference_jobs
	SET state = 'preparing', version = version + 1, updated_at = NOW()
	WHERE job_id = '11111111-1111-1111-1111-111111111111' AND version = 1;
	GET DIAGNOSTICS n = ROW_COUNT;
	ASSERT n = 1, 'job1 CAS reserved->preparing must match version 1';

	UPDATE rust_coord.inference_attempts
	SET state = 'prepared', lease_id = 'eeeeeeee-0000-0000-0000-000000000001', updated_at = NOW()
	WHERE attempt_id = 'aaaaaaaa-0000-0000-0000-000000000001' AND state = 'queued_to_socket';
	GET DIAGNOSTICS n = ROW_COUNT;
	ASSERT n = 1, 'attempt1 must move to prepared with a lease';

	UPDATE rust_coord.inference_jobs
	SET state = 'prepared', version = version + 1, updated_at = NOW()
	WHERE job_id = '11111111-1111-1111-1111-111111111111' AND version = 2;
	GET DIAGNOSTICS n = ROW_COUNT;
	ASSERT n = 1, 'job1 CAS preparing->prepared must match version 2';
	RAISE NOTICE 'PASS prepare: attempt leased, job version CAS 1->3';
END $$;

-- ---------------------------------------------------------------------------
-- Job 1 resize + freeze + start_authorized (plan §12.5, §12.4). Exact bound
-- from provider prepare: 5,000,000. New withdrawable component =
-- max(0, 5M - 6M nonwithdrawable) = 0, so 2,000,000 total and the full
-- 1,000,000 withdrawable provenance are refunded. Job version CAS 3->4.
-- ---------------------------------------------------------------------------
WITH op AS (
	INSERT INTO rust_coord.financial_operations
		(operation_key, kind, job_id, account_id,
		 amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
	VALUES
		('op.resize.job1', 'resize', '11111111-1111-1111-1111-111111111111', 'acct_consumer',
		 2000000, 1000000, '{"state":"start_authorized"}'::jsonb, 1)
	ON CONFLICT (operation_key) DO NOTHING
	RETURNING operation_key
), refund AS (
	UPDATE balances b
	SET balance_micro_usd = b.balance_micro_usd + 2000000,
	    withdrawable_micro_usd = b.withdrawable_micro_usd + 1000000,
	    updated_at = NOW()
	FROM op
	WHERE b.account_id = 'acct_consumer'
	RETURNING b.balance_micro_usd
), freeze_terms AS (
	UPDATE rust_coord.inference_jobs j
	SET reserved_total_micro_usd = 5000000,
	    reserved_withdrawable_micro_usd = 0,
	    concrete_model = 'qwen3-30b-a3b-4bit',
	    public_model = 'qwen3-30b',
	    pricing_version = 1,
	    rounding_version = 1,
	    billable_input_tokens = 1200,
	    bounded_output_tokens = 2000,
	    provider_stable_id = 'prov_1',
	    beneficiary_account_id = 'acct_provider',
	    provider_payout_micro_usd = 3400000,
	    platform_fee_micro_usd = 500000,
	    referral_beneficiary_account_id = 'acct_referrer',
	    referral_share_ppm = 200000,
	    request_digest = '\xd1600001',
	    state = 'start_authorized',
	    version = j.version + 1,
	    updated_at = NOW()
	FROM op
	WHERE j.job_id = '11111111-1111-1111-1111-111111111111' AND j.version = 3
	RETURNING j.job_id
)
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
SELECT 'acct_consumer', 'refund', 2000000, refund.balance_micro_usd,
	'11111111-1111-1111-1111-111111111111'
FROM refund;

DO $$
DECLARE
	n INTEGER;
BEGIN
	ASSERT (SELECT state FROM rust_coord.inference_jobs
		WHERE job_id = '11111111-1111-1111-1111-111111111111') = 'start_authorized',
		'job1 must be start_authorized after resize';
	ASSERT (SELECT balance_micro_usd FROM balances WHERE account_id = 'acct_consumer') = 5000000,
		'resize must refund 2000000 total';
	ASSERT (SELECT withdrawable_micro_usd FROM balances WHERE account_id = 'acct_consumer') = 4000000,
		'resize must restore the 1000000 withdrawable provenance';

	UPDATE rust_coord.inference_attempts
	SET state = 'started', updated_at = NOW()
	WHERE attempt_id = 'aaaaaaaa-0000-0000-0000-000000000001' AND state = 'prepared';
	GET DIAGNOSTICS n = ROW_COUNT;
	ASSERT n = 1, 'attempt1 must move to started';

	UPDATE rust_coord.inference_jobs
	SET state = 'running', version = version + 1, updated_at = NOW()
	WHERE job_id = '11111111-1111-1111-1111-111111111111' AND version = 4;
	GET DIAGNOSTICS n = ROW_COUNT;
	ASSERT n = 1, 'job1 CAS start_authorized->running must match version 4';
	RAISE NOTICE 'PASS resize+freeze: reservation 7000000->5000000, terms frozen, job running';
END $$;

-- Invariant 9.2.3: a second start-authorized attempt for job1 must violate
-- idx_rust_attempts_one_started_per_job.
DO $$
DECLARE
	violated BOOLEAN := FALSE;
BEGIN
	BEGIN
		INSERT INTO rust_coord.inference_attempts
			(attempt_id, job_id, provider_stable_id, session_epoch, coordinator_epoch,
			 lease_id, dispatch_nonce, request_digest, state)
		VALUES
			('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
			 'prov_2', 3, 1, 'eeeeeeee-0000-0000-0000-000000000002',
			 '\x6e6f6e636532', '\xd1600001', 'started');
	EXCEPTION WHEN unique_violation THEN
		violated := TRUE;
	END;
	ASSERT violated, 'invariant 9.2.3: second started attempt for one job must be rejected';
	RAISE NOTICE 'PASS invariant 9.2.3: second started attempt rejected by unique partial index';
END $$;

-- ---------------------------------------------------------------------------
-- Job 1 terminal receipt (plan §10.6, §12.8): insert once, then replay the
-- SAME digest — the replay only bumps received_count.
-- ---------------------------------------------------------------------------
INSERT INTO rust_coord.provider_terminals
	(attempt_id, terminal_digest, raw_terminal, outcome, error_class,
	 prompt_tokens, completion_tokens, reasoning_tokens, response_hash,
	 final_generated_tokens, rolling_hash_checkpoint, provider_signature,
	 origin_session_epoch, coordinator_epoch)
VALUES
	('aaaaaaaa-0000-0000-0000-000000000001', '\x7e001111',
	 '{"outcome":"completed","prompt_tokens":1200,"completion_tokens":800}'::jsonb,
	 'completed', NULL, 1200, 800, 0, '\xab5e0001', 800, '\xab5e0001', '\x51670001', 7, 1);

INSERT INTO rust_coord.provider_terminals
	(attempt_id, terminal_digest, raw_terminal, outcome, error_class,
	 prompt_tokens, completion_tokens, reasoning_tokens, response_hash,
	 final_generated_tokens, rolling_hash_checkpoint, provider_signature,
	 origin_session_epoch, coordinator_epoch)
VALUES
	('aaaaaaaa-0000-0000-0000-000000000001', '\x7e001111',
	 '{"outcome":"completed","prompt_tokens":1200,"completion_tokens":800}'::jsonb,
	 'completed', NULL, 1200, 800, 0, '\xab5e0001', 800, '\xab5e0001', '\x51670001', 7, 1)
ON CONFLICT (attempt_id, terminal_digest)
DO UPDATE SET received_count = rust_coord.provider_terminals.received_count + 1, updated_at = NOW();

DO $$
BEGIN
	ASSERT (SELECT received_count FROM rust_coord.provider_terminals
		WHERE attempt_id = 'aaaaaaaa-0000-0000-0000-000000000001'
		  AND terminal_digest = '\x7e001111') = 2,
		'duplicate terminal digest must bump received_count, not insert';
	RAISE NOTICE 'PASS terminal replay: same digest deduplicated (received_count = 2)';
END $$;

-- ---------------------------------------------------------------------------
-- Job 1 settlement (plan §12.6): one transaction-shaped statement. Actual
-- funded cost 4,000,000 from frozen terms; refund unused 1,000,000 total /
-- 0 withdrawable; credit provider (total + withdrawable, §12.11); insert
-- authoritative fee_allocations (NOT platform/referrer balance updates);
-- insert usage, provider_earnings, earnings_summary, ledger projections;
-- mark terminal disposition, attempt terminal_recorded, job settled
-- (version CAS 5->6).
-- ---------------------------------------------------------------------------
WITH op AS (
	INSERT INTO rust_coord.financial_operations
		(operation_key, kind, job_id, account_id,
		 amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
	VALUES
		('op.settle.job1', 'settle', '11111111-1111-1111-1111-111111111111', 'acct_consumer',
		 1000000, 0,
		 '{"charged":4000000,"payout":3400000,"platform_fee":500000,"referral_reward":100000}'::jsonb, 1)
	ON CONFLICT (operation_key) DO NOTHING
	RETURNING operation_key
), consumer_refund AS (
	UPDATE balances b
	SET balance_micro_usd = b.balance_micro_usd + 1000000,
	    updated_at = NOW()
	FROM op
	WHERE b.account_id = 'acct_consumer'
	RETURNING b.balance_micro_usd
), provider_credit AS (
	INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd)
	SELECT 'acct_provider', 3400000, 3400000 FROM op
	ON CONFLICT (account_id) DO UPDATE
	SET balance_micro_usd = balances.balance_micro_usd + 3400000,
	    withdrawable_micro_usd = balances.withdrawable_micro_usd + 3400000,
	    updated_at = NOW()
	RETURNING balances.balance_micro_usd
), fees AS (
	INSERT INTO rust_coord.fee_allocations
		(job_id, beneficiary_account_id, kind, amount_micro_usd, coordinator_epoch)
	SELECT '11111111-1111-1111-1111-111111111111', v.beneficiary, v.kind, v.amount, 1
	FROM op, (VALUES
		('platform', 'platform', 500000),
		('acct_referrer', 'referral', 100000)
	) AS v(beneficiary, kind, amount)
	RETURNING id
), usage_row AS (
	INSERT INTO usage
		(provider_id, consumer_key_hash, key_id, model, public_model,
		 prompt_tokens, completion_tokens, request_id, cost_micro_usd)
	SELECT 'prov_1', 'hash_smoke1', 'key_smoke1', 'qwen3-30b-a3b-4bit', 'qwen3-30b',
		1200, 800, '11111111-1111-1111-1111-111111111111', 4000000
	FROM op
	RETURNING id
), usage_total AS (
	INSERT INTO usage_totals (id, total_requests, total_prompt_tokens, total_completion_tokens)
	SELECT 1, 1, 1200, 800 FROM op
	ON CONFLICT (id) DO UPDATE
	SET total_requests = usage_totals.total_requests + 1,
	    total_prompt_tokens = usage_totals.total_prompt_tokens + 1200,
	    total_completion_tokens = usage_totals.total_completion_tokens + 800
	RETURNING id
), earning AS (
	INSERT INTO provider_earnings
		(account_id, provider_id, provider_key, job_id, model,
		 amount_micro_usd, prompt_tokens, completion_tokens)
	SELECT 'acct_provider', 'prov_1', 'prov_1', '11111111-1111-1111-1111-111111111111',
		'qwen3-30b-a3b-4bit', 3400000, 1200, 800
	FROM op
	ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING
	RETURNING id
), summary AS (
	INSERT INTO earnings_summary
		(key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens)
	SELECT v.key, v.key_type, 1, 3400000, 1200, 800
	FROM earning, (VALUES ('acct_provider', 'account'), ('prov_1', 'provider')) AS v(key, key_type)
	ON CONFLICT (key, key_type) DO UPDATE
	SET total_count = earnings_summary.total_count + 1,
	    total_micro_usd = earnings_summary.total_micro_usd + 3400000,
	    total_prompt_tokens = earnings_summary.total_prompt_tokens + 1200,
	    total_completion_tokens = earnings_summary.total_completion_tokens + 800,
	    updated_at = NOW()
	RETURNING key
), terminal AS (
	UPDATE rust_coord.provider_terminals t
	SET disposition = 'settled', disposition_at = NOW(), updated_at = NOW()
	FROM op
	WHERE t.attempt_id = 'aaaaaaaa-0000-0000-0000-000000000001'
	  AND t.terminal_digest = '\x7e001111'
	  AND t.disposition IS NULL
	RETURNING t.attempt_id
), attempt AS (
	UPDATE rust_coord.inference_attempts a
	SET state = 'terminal_recorded', updated_at = NOW()
	FROM terminal
	WHERE a.attempt_id = terminal.attempt_id AND a.state = 'started'
	RETURNING a.attempt_id
), job AS (
	UPDATE rust_coord.inference_jobs j
	SET state = 'settled',
	    outcome = 'completed',
	    usage_prompt_tokens = 1200,
	    usage_completion_tokens = 800,
	    usage_reasoning_tokens = 0,
	    response_hash = '\xab5e0001',
	    accepted_chunk_seq = 42,
	    accepted_cumulative_tokens = 800,
	    version = j.version + 1,
	    updated_at = NOW()
	FROM op
	WHERE j.job_id = '11111111-1111-1111-1111-111111111111' AND j.version = 5
	RETURNING j.job_id
), consumer_ledger AS (
	INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
	SELECT 'acct_consumer', 'refund', 1000000, consumer_refund.balance_micro_usd,
		'11111111-1111-1111-1111-111111111111'
	FROM consumer_refund
	RETURNING id
)
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
SELECT 'acct_provider', 'payout', 3400000, provider_credit.balance_micro_usd,
	'11111111-1111-1111-1111-111111111111'
FROM provider_credit;

-- Terminal acknowledgement happens only after the settlement committed
-- (plan §12.8); here it is a separate statement in the same smoke.
UPDATE rust_coord.inference_attempts
SET state = 'acknowledged', updated_at = NOW()
WHERE attempt_id = 'aaaaaaaa-0000-0000-0000-000000000001' AND state = 'terminal_recorded';

DO $$
BEGIN
	ASSERT (SELECT state FROM rust_coord.inference_jobs
		WHERE job_id = '11111111-1111-1111-1111-111111111111') = 'settled',
		'job1 must be settled';
	ASSERT (SELECT balance_micro_usd FROM balances WHERE account_id = 'acct_consumer') = 6000000,
		'consumer balance after settle must be 6000000';
	ASSERT (SELECT withdrawable_micro_usd FROM balances WHERE account_id = 'acct_consumer') = 4000000,
		'consumer withdrawable must be preserved at 4000000 (provenance, plan §4.3)';
	ASSERT (SELECT balance_micro_usd FROM balances WHERE account_id = 'acct_provider') = 3400000,
		'provider must be credited 3400000';
	ASSERT (SELECT withdrawable_micro_usd FROM balances WHERE account_id = 'acct_provider') = 3400000,
		'provider earnings must be withdrawable';
	ASSERT NOT EXISTS (SELECT 1 FROM balances WHERE account_id = 'platform'),
		'settlement must NOT touch the platform balance synchronously (plan §12.6)';
	RAISE NOTICE 'PASS settle: consumer 6000000/4000000, provider 3400000/3400000, platform deferred';
END $$;

-- ---------------------------------------------------------------------------
-- Job 2: reserve then release (plan §12.7). nonwithdrawable = 6M - 4M = 2M,
-- withdrawable component = max(0, 4M - 2M) = 2M. Release restores exactly.
-- ---------------------------------------------------------------------------
WITH op AS (
	INSERT INTO rust_coord.financial_operations
		(operation_key, kind, job_id, account_id,
		 amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
	VALUES
		('op.reserve.job2', 'reserve', '22222222-2222-2222-2222-222222222222', 'acct_consumer',
		 -4000000, -2000000, '{"state":"reserved"}'::jsonb, 1)
	ON CONFLICT (operation_key) DO NOTHING
	RETURNING operation_key
), debit AS (
	UPDATE balances b
	SET balance_micro_usd = b.balance_micro_usd - 4000000,
	    withdrawable_micro_usd = b.withdrawable_micro_usd
	        - GREATEST(0, 4000000 - (b.balance_micro_usd - b.withdrawable_micro_usd)),
	    updated_at = NOW()
	FROM op
	WHERE b.account_id = 'acct_consumer'
	  AND b.balance_micro_usd >= 4000000
	RETURNING b.balance_micro_usd
), job AS (
	INSERT INTO rust_coord.inference_jobs
		(job_id, account_id, api_key_id, coordinator_epoch, state, version,
		 reserve_operation_key,
		 reserved_total_micro_usd, reserved_withdrawable_micro_usd,
		 first_content_deadline, request_deadline)
	SELECT
		'22222222-2222-2222-2222-222222222222', 'acct_consumer', 'key_smoke1', 1, 'reserved', 1,
		'op.reserve.job2',
		4000000, 2000000,
		NOW() + INTERVAL '30 seconds', NOW() + INTERVAL '120 seconds'
	FROM debit
)
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
SELECT 'acct_consumer', 'charge', -4000000, debit.balance_micro_usd,
	'22222222-2222-2222-2222-222222222222'
FROM debit;

-- The job2 attempt reaches prepared, then the lease is aborted (provider
-- rejected / expired) and the job is released.
INSERT INTO rust_coord.inference_attempts
	(attempt_id, job_id, provider_stable_id, session_epoch, coordinator_epoch,
	 lease_id, dispatch_nonce, request_digest, state)
VALUES
	('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
	 'prov_1', 7, 1, 'eeeeeeee-0000-0000-0000-000000000003',
	 '\x6e6f6e636533', '\xd1600002', 'queued_to_socket');
UPDATE rust_coord.inference_attempts
SET state = 'aborted', updated_at = NOW()
WHERE attempt_id = 'bbbbbbbb-0000-0000-0000-000000000001' AND state = 'queued_to_socket';

-- Release (plan §12.7): one idempotent statement restores the EXACT total and
-- withdrawable reservation recorded in the job. Version CAS 1->2.
WITH op AS (
	INSERT INTO rust_coord.financial_operations
		(operation_key, kind, job_id, account_id,
		 amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
	VALUES
		('op.release.job2', 'release', '22222222-2222-2222-2222-222222222222', 'acct_consumer',
		 4000000, 2000000, '{"state":"released"}'::jsonb, 1)
	ON CONFLICT (operation_key) DO NOTHING
	RETURNING operation_key
), job AS (
	UPDATE rust_coord.inference_jobs j
	SET state = 'released', outcome = 'released_before_start',
	    version = j.version + 1, updated_at = NOW()
	FROM op
	WHERE j.job_id = '22222222-2222-2222-2222-222222222222' AND j.version = 1
	RETURNING j.reserved_total_micro_usd, j.reserved_withdrawable_micro_usd
), refund AS (
	UPDATE balances b
	SET balance_micro_usd = b.balance_micro_usd + job.reserved_total_micro_usd,
	    withdrawable_micro_usd = b.withdrawable_micro_usd + job.reserved_withdrawable_micro_usd,
	    updated_at = NOW()
	FROM job
	WHERE b.account_id = 'acct_consumer'
	RETURNING b.balance_micro_usd
)
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
SELECT 'acct_consumer', 'refund', 4000000, refund.balance_micro_usd,
	'22222222-2222-2222-2222-222222222222'
FROM refund;

DO $$
BEGIN
	ASSERT (SELECT state FROM rust_coord.inference_jobs
		WHERE job_id = '22222222-2222-2222-2222-222222222222') = 'released',
		'job2 must be released';
	ASSERT (SELECT balance_micro_usd FROM balances WHERE account_id = 'acct_consumer') = 6000000,
		'release must restore the exact total (6000000)';
	ASSERT (SELECT withdrawable_micro_usd FROM balances WHERE account_id = 'acct_consumer') = 4000000,
		'release must restore the exact withdrawable provenance (4000000)';
	RAISE NOTICE 'PASS release: exact total + withdrawable provenance restored';
END $$;

-- A terminal arriving AFTER release is recorded and acknowledged as late but
-- moves no money (plan §12.7); a second, different digest for the same
-- attempt is insertable and flagged as a conflict (plan §12.8, §10.6).
INSERT INTO rust_coord.provider_terminals
	(attempt_id, terminal_digest, raw_terminal, outcome, error_class,
	 prompt_tokens, completion_tokens, reasoning_tokens, response_hash,
	 final_generated_tokens, rolling_hash_checkpoint, provider_signature,
	 origin_session_epoch, coordinator_epoch, disposition, disposition_at)
VALUES
	('bbbbbbbb-0000-0000-0000-000000000001', '\x7e002222',
	 '{"outcome":"cancelled"}'::jsonb,
	 'cancelled', 'cancelled', 900, 0, 0, '\xab5e0002', 0, NULL, '\x51670002', 7, 1,
	 'late', NOW());

INSERT INTO rust_coord.provider_terminals
	(attempt_id, terminal_digest, raw_terminal, outcome, error_class,
	 prompt_tokens, completion_tokens, reasoning_tokens, response_hash,
	 final_generated_tokens, rolling_hash_checkpoint, provider_signature,
	 origin_session_epoch, coordinator_epoch, disposition, disposition_at)
VALUES
	('bbbbbbbb-0000-0000-0000-000000000001', '\x7e003333',
	 '{"outcome":"completed"}'::jsonb,
	 'completed', NULL, 900, 50, 0, '\xab5e0003', 50, '\xab5e0003', '\x51670003', 7, 1,
	 'conflict', NOW());

UPDATE rust_coord.provider_terminals
SET conflict = TRUE, updated_at = NOW()
WHERE attempt_id = 'bbbbbbbb-0000-0000-0000-000000000001';

DO $$
BEGIN
	ASSERT (SELECT COUNT(*) FROM rust_coord.provider_terminals
		WHERE attempt_id = 'bbbbbbbb-0000-0000-0000-000000000001' AND conflict) = 2,
		'same attempt + different digest must be insertable and flagged';
	RAISE NOTICE 'PASS terminal conflict: two digests for one attempt stored, both flagged, no money moved';
END $$;

-- ---------------------------------------------------------------------------
-- Fee projection (plan §12.6): the bounded single-writer worker folds the
-- authoritative fee_allocations into the materialized platform/referrer
-- balances and their legacy ledger projections. Platform fees credit total
-- only; referral rewards credit total + withdrawable (plan §12.11).
-- ---------------------------------------------------------------------------
WITH claimed AS (
	SELECT id, beneficiary_account_id, kind, amount_micro_usd
	FROM rust_coord.fee_allocations
	WHERE NOT projected
	ORDER BY created_at
	FOR UPDATE SKIP LOCKED
), credited AS (
	INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd)
	SELECT beneficiary_account_id,
	       SUM(amount_micro_usd),
	       COALESCE(SUM(amount_micro_usd) FILTER (WHERE kind = 'referral'), 0)
	FROM claimed
	GROUP BY beneficiary_account_id
	ON CONFLICT (account_id) DO UPDATE
	SET balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
	    withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
	    updated_at = NOW()
	RETURNING account_id, balance_micro_usd
), ledger AS (
	INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
	SELECT c.beneficiary_account_id,
	       CASE c.kind WHEN 'platform' THEN 'platform_fee' ELSE 'referral_reward' END,
	       c.amount_micro_usd,
	       cr.balance_micro_usd,
	       '11111111-1111-1111-1111-111111111111'
	FROM claimed c
	JOIN credited cr ON cr.account_id = c.beneficiary_account_id
	RETURNING id
), ops AS (
	INSERT INTO rust_coord.financial_operations
		(operation_key, kind, job_id, account_id,
		 amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
	SELECT 'op.feeproj.' || c.id, 'fee_projection', '11111111-1111-1111-1111-111111111111',
		c.beneficiary_account_id, c.amount_micro_usd,
		CASE c.kind WHEN 'referral' THEN c.amount_micro_usd ELSE 0 END,
		'{}'::jsonb, 1
	FROM claimed c
	ON CONFLICT (operation_key) DO NOTHING
	RETURNING operation_key
)
UPDATE rust_coord.fee_allocations f
SET projected = TRUE, projected_at = NOW()
FROM claimed
WHERE f.id = claimed.id;

DO $$
BEGIN
	ASSERT (SELECT balance_micro_usd FROM balances WHERE account_id = 'platform') = 500000,
		'platform balance must equal its fee allocation';
	ASSERT (SELECT withdrawable_micro_usd FROM balances WHERE account_id = 'platform') = 0,
		'platform fees credit total only (plan §12.11)';
	ASSERT (SELECT balance_micro_usd FROM balances WHERE account_id = 'acct_referrer') = 100000,
		'referrer balance must equal its reward allocation';
	ASSERT (SELECT withdrawable_micro_usd FROM balances WHERE account_id = 'acct_referrer') = 100000,
		'referral rewards are withdrawable (plan §12.11)';
	ASSERT (SELECT COUNT(*) FROM rust_coord.fee_allocations WHERE NOT projected) = 0,
		'fee-projection backlog must be zero (plan §26.1)';
	RAISE NOTICE 'PASS fee projection: platform 500000 (total only), referrer 100000 (withdrawable), backlog 0';
END $$;

-- ---------------------------------------------------------------------------
-- Final invariant sweep (plan §9.3, §26.3).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
	job1_net BIGINT;
	job1_wd_net BIGINT;
	job2_net BIGINT;
	job2_wd_net BIGINT;
	fee_sum BIGINT;
	bad_ledger INTEGER;
BEGIN
	-- 9.3.6 / 26.3: consumer reservation equals actual charge plus exact
	-- refund. Net consumer-side flow for job1 across reserve/resize/settle
	-- must equal -charge.
	SELECT COALESCE(SUM(amount_total_micro_usd), 0), COALESCE(SUM(amount_withdrawable_micro_usd), 0)
	INTO job1_net, job1_wd_net
	FROM rust_coord.financial_operations
	WHERE job_id = '11111111-1111-1111-1111-111111111111'
	  AND kind IN ('reserve', 'resize', 'settle');
	ASSERT job1_net = -4000000,
		format('job1 net consumer flow %s, want -4000000 (= -actual charge)', job1_net);
	ASSERT job1_wd_net = 0,
		format('job1 net withdrawable flow %s, want 0 (provenance fully restored)', job1_wd_net);

	-- 9.3.5 / 26.3: provider payout plus platform and referral allocations
	-- equal collected cost; credit never exceeds collected funds.
	SELECT COALESCE(SUM(amount_micro_usd), 0) INTO fee_sum
	FROM rust_coord.fee_allocations
	WHERE job_id = '11111111-1111-1111-1111-111111111111';
	ASSERT 3400000 + fee_sum = 4000000,
		format('payout 3400000 + fees %s must equal collected 4000000', fee_sum);

	-- 9.3.2/9.3.6: released job nets to exactly zero in both components.
	SELECT COALESCE(SUM(amount_total_micro_usd), 0), COALESCE(SUM(amount_withdrawable_micro_usd), 0)
	INTO job2_net, job2_wd_net
	FROM rust_coord.financial_operations
	WHERE job_id = '22222222-2222-2222-2222-222222222222';
	ASSERT job2_net = 0, format('job2 net flow %s, want 0', job2_net);
	ASSERT job2_wd_net = 0, format('job2 net withdrawable flow %s, want 0', job2_wd_net);

	-- Legacy projection consistency: every balance equals the sum of its
	-- ledger entries (the Go coordinator's own invariant).
	SELECT COUNT(*) INTO bad_ledger
	FROM balances b
	WHERE b.balance_micro_usd <> COALESCE((
		SELECT SUM(l.amount_micro_usd) FROM ledger_entries l
		WHERE l.account_id = b.account_id
	), 0);
	ASSERT bad_ledger = 0, format('%s account(s) where balance != SUM(ledger)', bad_ledger);

	-- 26.3: usage and provider earnings exist exactly once for the settled
	-- job and never for the released one.
	ASSERT (SELECT COUNT(*) FROM usage
		WHERE request_id = '11111111-1111-1111-1111-111111111111') = 1,
		'settled job must have exactly one usage row';
	ASSERT (SELECT COUNT(*) FROM provider_earnings
		WHERE job_id = '11111111-1111-1111-1111-111111111111') = 1,
		'settled job must have exactly one provider earning';
	ASSERT NOT EXISTS (SELECT 1 FROM usage
		WHERE request_id = '22222222-2222-2222-2222-222222222222'),
		'released job must have no usage row';
	ASSERT NOT EXISTS (SELECT 1 FROM provider_earnings
		WHERE job_id = '22222222-2222-2222-2222-222222222222'),
		'released job must have no provider earning';
	ASSERT (SELECT total_requests FROM usage_totals WHERE id = 1) = 1,
		'usage_totals must count exactly the settled job';
	ASSERT (SELECT total_micro_usd FROM earnings_summary
		WHERE key = 'prov_1' AND key_type = 'provider') = 3400000,
		'earnings_summary must reflect the single payout';

	-- 9.3.3 / 26.1 quiescence: every job in a terminal money state, no
	-- terminal awaiting settlement, no pending outbox work.
	ASSERT NOT EXISTS (SELECT 1 FROM rust_coord.inference_jobs
		WHERE state NOT IN ('settled', 'released', 'settled_reviewed', 'released_reviewed')),
		'no job may remain in a non-terminal money state';
	ASSERT NOT EXISTS (SELECT 1 FROM rust_coord.provider_terminals WHERE disposition IS NULL),
		'no terminal may remain without a disposition';
	ASSERT NOT EXISTS (SELECT 1 FROM rust_coord.outbox WHERE state = 'pending'),
		'no pending outbox work may remain';
	ASSERT NOT EXISTS (SELECT 1 FROM rust_coord.external_intents WHERE NOT legacy_projected),
		'no external intent may lack its legacy projection';

	RAISE NOTICE 'PASS invariants 9.3: reservation = charge + refund, payout + fees = collected, provenance preserved, ledger consistent, quiescent';
END $$;

COMMIT;
