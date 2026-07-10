-- 0007_external_events_and_intents.sql
--
-- rust_coord.external_events — inbound external event inbox (plan §12.10).
-- rust_coord.external_intents — outbound withdrawal/payout outbox (plan §12.11).
--
-- Timeouts: bounded per plan §20; new empty tables only.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Plan §12.10: the Stripe (et al.) inbox. The paid-webhook transaction
-- inserts (source, event_id) idempotently BEFORE applying any credit; a
-- duplicate delivery conflicts here and applies nothing. Unknown or
-- mismatched sessions become auditable orphans, never metadata-driven credits.
CREATE TABLE rust_coord.external_events (
	source TEXT NOT NULL,
	event_id TEXT NOT NULL,
	kind TEXT NOT NULL DEFAULT '',
	payload JSONB NOT NULL DEFAULT '{}'::jsonb,
	-- 'applied' moved money/state; 'orphaned' was verified but matched no
	-- local order; 'ignored' was a recognized no-op event type.
	status TEXT NOT NULL DEFAULT 'applied' CHECK (status IN ('applied', 'orphaned', 'ignored')),
	coordinator_epoch BIGINT NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	PRIMARY KEY (source, event_id)
);
COMMENT ON TABLE rust_coord.external_events IS
	'Plan §12.10: idempotent external event inbox keyed by (source, event_id); duplicate webhook delivery conflicts here and applies nothing.';

-- Plan §12.11: durable outbound payout intents. The withdrawal-request
-- transaction debits balances, creates this intent plus the compatible legacy
-- stripe_withdrawals projection, and commits BEFORE any Stripe I/O. A bounded
-- outbox worker then calls Stripe with the stable operation key as the Stripe
-- idempotency key. An ambiguous Stripe response parks the intent in
-- 'external_unknown' — never auto-refunded (plan §9.3, §12.11) — until
-- reconciliation by idempotency key resolves it. Go rollback is blocked while
-- any intent lacks a legacy projection (legacy_projected = FALSE) or remains
-- external_unknown without a Go-reconcilable projection (§26.1 step 5).
CREATE TABLE rust_coord.external_intents (
	intent_id UUID PRIMARY KEY,
	-- Also the Stripe idempotency key; one row in financial_operations.
	operation_key TEXT NOT NULL UNIQUE,
	account_id TEXT NOT NULL,
	kind TEXT NOT NULL DEFAULT 'stripe_withdrawal' CHECK (kind IN ('stripe_withdrawal')),

	-- Provenance debited by the request transaction (plan §12.11 credit
	-- semantics): definitive failure restores exactly these amounts.
	amount_total_micro_usd BIGINT NOT NULL CHECK (amount_total_micro_usd >= 0),
	amount_withdrawable_micro_usd BIGINT NOT NULL CHECK (amount_withdrawable_micro_usd >= 0),

	state TEXT NOT NULL DEFAULT 'created' CHECK (state IN (
		'created',          -- debited + committed, not yet sent to Stripe
		'submitted',        -- Stripe call in flight / accepted
		'external_unknown', -- ambiguous Stripe response; reconcile, never auto-refund
		'succeeded',        -- Stripe confirmed transfer/payout
		'failed_refunded'   -- definitive failure; provenance restored exactly
	)),

	stripe_transfer_id TEXT NOT NULL DEFAULT '',
	stripe_payout_id TEXT NOT NULL DEFAULT '',
	failure_reason TEXT NOT NULL DEFAULT '',

	-- TRUE once the legacy stripe_withdrawals row reflects this intent's
	-- current state, so a rolled-back Go build sees an exact projection
	-- (plan §12.11, §26.1 step 5).
	legacy_projected BOOLEAN NOT NULL DEFAULT FALSE,

	coordinator_epoch BIGINT NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

	CHECK (amount_withdrawable_micro_usd <= amount_total_micro_usd)
);
COMMENT ON TABLE rust_coord.external_intents IS
	'Plan §12.11: durable withdrawal/payout outbox; external_unknown is reconciled by idempotency key and never auto-refunded.';

-- Recovery sweeper (plan §18.1): Stripe external-unknown reconciliation.
CREATE INDEX idx_rust_intents_external_unknown
	ON rust_coord.external_intents (updated_at)
	WHERE state = 'external_unknown';

-- Outbox worker scan set: intents not yet in a terminal external state.
CREATE INDEX idx_rust_intents_pending
	ON rust_coord.external_intents (created_at)
	WHERE state IN ('created', 'submitted');

-- Rollback gate (§26.1): any live intent whose legacy projection lags.
CREATE INDEX idx_rust_intents_unprojected
	ON rust_coord.external_intents (updated_at)
	WHERE NOT legacy_projected;

CREATE INDEX idx_rust_intents_account
	ON rust_coord.external_intents (account_id, created_at DESC);

UPDATE rust_coord.schema_meta
SET schema_version = 7, updated_at = NOW()
WHERE id = 1;
