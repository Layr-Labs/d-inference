-- legacy_baseline.sql
--
-- TEST-ONLY baseline replicating the Go coordinator's legacy schema for
-- ephemeral databases; production databases already have these tables —
-- never apply this in production.
--
-- Source of truth: coordinator/store/postgres.go migrate(). Each CREATE TABLE
-- below is the FINAL shape after every inline Go migration: columns that
-- postgres.go adds via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` after the
-- CREATE are appended here in ALTER order (matching what an upgraded fresh Go
-- database converges to), and columns the Go migrations DROP (billing_sessions
-- .chain, users.solana_*, releases.image_bridge_hash) are omitted. Plain
-- CREATE TABLE (no IF NOT EXISTS) is deliberate: applying this to a database
-- that already has the tables fails loudly instead of silently diverging.
--
-- Scope: only the legacy tables the Rust coordinator touches — compatibility
-- projections written inside Rust transactions (balances, ledger_entries,
-- usage, usage_totals, provider_earnings, earnings_summary, billing_sessions,
-- stripe_withdrawals), auth reads (api_keys, users), referral resolution at
-- freeze time (referrers, referrals), and the catalog/pricing snapshot
-- (model_registry, model_versions, model_version_files, model_active_versions,
-- model_aliases, model_prices). Telemetry, attestation, release, and device
-- tables are Go-only and not baselined.

-- Consumer/provider account balances. withdrawable_micro_usd was added by
-- ALTER after the original CREATE (postgres.go "Withdrawable balance"
-- migration); the boot-time withdrawable backfill UPDATE is intentionally NOT
-- replicated (plan §4.4 removes it before Rust shares the database).
CREATE TABLE balances (
	account_id TEXT PRIMARY KEY,
	balance_micro_usd BIGINT NOT NULL DEFAULT 0,
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	withdrawable_micro_usd BIGINT NOT NULL DEFAULT 0
);

-- Append-only money journal. entry_type values come from store.LedgerEntryType
-- (deposit, charge, payout, platform_fee, withdrawal, referral_reward,
-- stripe_deposit, stripe_payout, invite_credit, refund, admin_credit,
-- admin_reward, migration, provider_floor_draw); the column is TEXT with no
-- CHECK in Go, so none is added here.
CREATE TABLE ledger_entries (
	id BIGSERIAL PRIMARY KEY,
	account_id TEXT NOT NULL,
	entry_type TEXT NOT NULL,
	amount_micro_usd BIGINT NOT NULL,
	balance_after BIGINT NOT NULL,
	reference TEXT NOT NULL DEFAULT '',
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_ledger_account ON ledger_entries(account_id, created_at DESC);
-- Predicate mirrors rewardLedgerTypesSQLList() = RewardLedgerTypes
-- (LedgerReferralReward, LedgerAdminReward).
CREATE INDEX idx_ledger_reward ON ledger_entries(account_id, created_at DESC)
	WHERE entry_type IN ('referral_reward', 'admin_reward');

-- Canonical usage records. Final CREATE in postgres.go already contains the
-- key_id/public_model/request_id/cost_micro_usd/request_location columns the
-- older ALTERs added, in this order.
CREATE TABLE usage (
	id BIGSERIAL PRIMARY KEY,
	provider_id TEXT NOT NULL,
	consumer_key_hash TEXT NOT NULL,
	key_id TEXT NOT NULL DEFAULT '',
	model TEXT NOT NULL,
	public_model TEXT NOT NULL DEFAULT '',
	prompt_tokens INTEGER NOT NULL,
	completion_tokens INTEGER NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	request_id TEXT NOT NULL DEFAULT '',
	cost_micro_usd BIGINT NOT NULL DEFAULT 0,
	request_location JSONB
);
CREATE INDEX idx_usage_created ON usage(created_at DESC);
CREATE INDEX idx_usage_consumer ON usage(consumer_key_hash, created_at DESC);
CREATE INDEX idx_usage_provider ON usage(provider_id, created_at DESC);
CREATE INDEX idx_usage_key ON usage(key_id, created_at DESC) WHERE key_id <> '';
CREATE INDEX idx_usage_request_location_notnull ON usage(created_at DESC)
	WHERE request_location IS NOT NULL;

-- Materialized usage totals — singleton counter row incremented by Go
-- RecordUsage; Rust settlement projections must keep incrementing it.
CREATE TABLE usage_totals (
	id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
	total_requests BIGINT NOT NULL DEFAULT 0,
	total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
	total_completion_tokens BIGINT NOT NULL DEFAULT 0
);

-- Per-job provider earnings. The partial unique job_id index is built
-- CONCURRENTLY out-of-band in production (DAR-349,
-- ensureProviderEarningsJobIndex); on an empty test database a plain build is
-- equivalent and backs the same ON CONFLICT (job_id) idempotency.
CREATE TABLE provider_earnings (
	id BIGSERIAL PRIMARY KEY,
	account_id TEXT NOT NULL,
	provider_id TEXT NOT NULL,
	provider_key TEXT NOT NULL DEFAULT '',
	job_id TEXT NOT NULL,
	model TEXT NOT NULL,
	amount_micro_usd BIGINT NOT NULL,
	prompt_tokens INTEGER NOT NULL DEFAULT 0,
	completion_tokens INTEGER NOT NULL DEFAULT 0,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_provider_earnings_account ON provider_earnings(account_id, created_at DESC);
CREATE INDEX idx_provider_earnings_provider ON provider_earnings(provider_key, created_at DESC);
CREATE UNIQUE INDEX idx_provider_earnings_job ON provider_earnings(job_id) WHERE job_id <> '';

-- Materialized earnings summaries, maintained atomically with earning inserts
-- (Go CreditProviderAccount; Rust settlement projection mirrors it).
CREATE TABLE earnings_summary (
	key TEXT NOT NULL,
	key_type TEXT NOT NULL,
	total_count BIGINT NOT NULL DEFAULT 0,
	total_micro_usd BIGINT NOT NULL DEFAULT 0,
	total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
	total_completion_tokens BIGINT NOT NULL DEFAULT 0,
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	PRIMARY KEY (key, key_type)
);

-- Stripe Checkout deposit sessions. The `chain` column was dropped by a Go
-- migration and is omitted.
CREATE TABLE billing_sessions (
	id TEXT PRIMARY KEY,
	account_id TEXT NOT NULL,
	payment_method TEXT NOT NULL,
	amount_micro_usd BIGINT NOT NULL,
	external_id TEXT NOT NULL DEFAULT '',
	status TEXT NOT NULL DEFAULT 'pending',
	referral_code TEXT NOT NULL DEFAULT '',
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	completed_at TIMESTAMPTZ
);
CREATE INDEX idx_billing_sessions_account ON billing_sessions(account_id);
CREATE INDEX idx_billing_sessions_external ON billing_sessions(external_id);

-- Stripe Connect withdrawal rows — the legacy projection target for
-- rust_coord.external_intents. fee_refunded and sweep_payout_id were added by
-- ALTER after the original CREATE.
CREATE TABLE stripe_withdrawals (
	id TEXT PRIMARY KEY,
	account_id TEXT NOT NULL,
	stripe_account_id TEXT NOT NULL,
	transfer_id TEXT NOT NULL DEFAULT '',
	payout_id TEXT NOT NULL DEFAULT '',
	amount_micro_usd BIGINT NOT NULL,
	fee_micro_usd BIGINT NOT NULL DEFAULT 0,
	net_micro_usd BIGINT NOT NULL,
	method TEXT NOT NULL,
	status TEXT NOT NULL,
	failure_reason TEXT NOT NULL DEFAULT '',
	refunded BOOLEAN NOT NULL DEFAULT FALSE,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	fee_refunded BOOLEAN NOT NULL DEFAULT FALSE,
	sweep_payout_id TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_stripe_withdrawals_account ON stripe_withdrawals(account_id, created_at DESC);
CREATE UNIQUE INDEX idx_stripe_withdrawals_transfer ON stripe_withdrawals(transfer_id) WHERE transfer_id != '';
CREATE UNIQUE INDEX idx_stripe_withdrawals_payout ON stripe_withdrawals(payout_id) WHERE payout_id != '';
CREATE INDEX idx_stripe_withdrawals_status ON stripe_withdrawals(status, created_at);
CREATE INDEX idx_stripe_withdrawals_stripe_account ON stripe_withdrawals(stripe_account_id, status);
CREATE INDEX idx_stripe_withdrawals_sweep_payout ON stripe_withdrawals(sweep_payout_id) WHERE sweep_payout_id != '';

-- Consumer API keys (Rust auth reads these). id/name/limit_*/allowed_models/
-- expires_at/last_used_at/self_route_only were added by ALTERs after the
-- original CREATE, in this order.
CREATE TABLE api_keys (
	key_hash TEXT PRIMARY KEY,
	raw_prefix TEXT NOT NULL,
	owner_account_id TEXT NOT NULL DEFAULT '',
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	active BOOLEAN NOT NULL DEFAULT TRUE,
	id TEXT NOT NULL DEFAULT '',
	name TEXT NOT NULL DEFAULT '',
	limit_micro_usd BIGINT,
	limit_reset TEXT NOT NULL DEFAULT 'none',
	rpm_limit BIGINT,
	itpm_limit BIGINT,
	otpm_limit BIGINT,
	allowed_models TEXT NOT NULL DEFAULT '',
	expires_at TIMESTAMPTZ,
	last_used_at TIMESTAMPTZ,
	self_route_only BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE UNIQUE INDEX idx_api_keys_id ON api_keys(id) WHERE id <> '';
CREATE INDEX idx_api_keys_owner ON api_keys(owner_account_id) WHERE owner_account_id <> '';

-- Privy identity → internal account mapping (the closest thing to an
-- `accounts` table). role/platform_fee_percent are in the final CREATE; the
-- stripe_* columns were added by ALTERs in this order; solana_* columns were
-- dropped and are omitted.
CREATE TABLE users (
	account_id TEXT PRIMARY KEY,
	privy_user_id TEXT UNIQUE NOT NULL,
	email TEXT NOT NULL DEFAULT '',
	role TEXT NOT NULL DEFAULT '',
	platform_fee_percent BIGINT,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	stripe_account_id TEXT NOT NULL DEFAULT '',
	stripe_account_status TEXT NOT NULL DEFAULT '',
	stripe_account_country TEXT NOT NULL DEFAULT '',
	stripe_destination_type TEXT NOT NULL DEFAULT '',
	stripe_destination_last4 TEXT NOT NULL DEFAULT '',
	stripe_instant_eligible BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE UNIQUE INDEX idx_users_privy ON users(privy_user_id);
CREATE UNIQUE INDEX idx_users_stripe_account ON users(stripe_account_id) WHERE stripe_account_id != '';

-- Referral system — read at freeze time to pin the referral beneficiary.
CREATE TABLE referrers (
	account_id TEXT PRIMARY KEY,
	code TEXT UNIQUE NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_referrers_code ON referrers(code);

CREATE TABLE referrals (
	referred_account TEXT PRIMARY KEY,
	referrer_code TEXT NOT NULL REFERENCES referrers(code),
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_referrals_code ON referrals(referrer_code);

-- Per-account (and account_id='platform' default) model price overrides —
-- read when freezing pricing terms.
CREATE TABLE model_prices (
	account_id TEXT NOT NULL,
	model TEXT NOT NULL,
	input_price BIGINT NOT NULL,
	output_price BIGINT NOT NULL,
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	PRIMARY KEY (account_id, model)
);

-- Model registry — the catalog snapshot source. max_context_length /
-- max_output_length / runtime_parameters are in the final CREATE (their
-- ALTERs are no-ops on a fresh database).
CREATE TABLE model_registry (
	id TEXT PRIMARY KEY,
	display_name TEXT NOT NULL,
	family TEXT NOT NULL DEFAULT '',
	architecture TEXT NOT NULL DEFAULT '',
	quantization TEXT NOT NULL DEFAULT '',
	max_context_length INTEGER NOT NULL DEFAULT 0,
	max_output_length INTEGER NOT NULL DEFAULT 0,
	min_ram_gb INTEGER NOT NULL DEFAULT 0,
	capabilities TEXT[] NOT NULL DEFAULT '{}',
	status TEXT NOT NULL DEFAULT 'beta',
	description TEXT NOT NULL DEFAULT '',
	runtime_parameters JSONB NOT NULL DEFAULT '{}',
	metadata JSONB NOT NULL DEFAULT '{}',
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_model_registry_status ON model_registry(status);

CREATE TABLE model_versions (
	id BIGSERIAL PRIMARY KEY,
	model_id TEXT NOT NULL REFERENCES model_registry(id) ON DELETE CASCADE,
	version TEXT NOT NULL,
	r2_prefix TEXT NOT NULL,
	aggregate_sha256 TEXT NOT NULL,
	total_size_bytes BIGINT NOT NULL,
	file_count INTEGER NOT NULL,
	status TEXT NOT NULL DEFAULT 'ready',
	uploaded_by TEXT NOT NULL DEFAULT '',
	uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	promoted_at TIMESTAMPTZ,
	metadata JSONB NOT NULL DEFAULT '{}',
	UNIQUE(model_id, version)
);
CREATE INDEX idx_model_versions_model ON model_versions(model_id);

CREATE TABLE model_version_files (
	id BIGSERIAL PRIMARY KEY,
	model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE CASCADE,
	path TEXT NOT NULL,
	size_bytes BIGINT NOT NULL,
	sha256 TEXT NOT NULL,
	role TEXT NOT NULL,
	UNIQUE(model_version_id, path)
);
CREATE INDEX idx_model_version_files_version ON model_version_files(model_version_id);

CREATE TABLE model_active_versions (
	model_id TEXT PRIMARY KEY REFERENCES model_registry(id) ON DELETE CASCADE,
	model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE RESTRICT,
	activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Public alias → concrete build mapping. desired_build/previous_build/
-- retired_builds were added by ALTERs after the original CREATE; the legacy
-- `builds` JSONB column is retained (no longer read or written) exactly as in
-- Go.
CREATE TABLE model_aliases (
	alias_id TEXT PRIMARY KEY,
	display_name TEXT NOT NULL DEFAULT '',
	builds JSONB NOT NULL DEFAULT '[]'::jsonb,
	active BOOLEAN NOT NULL DEFAULT TRUE,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	desired_build TEXT NOT NULL DEFAULT '',
	previous_build TEXT NOT NULL DEFAULT '',
	retired_builds JSONB NOT NULL DEFAULT '[]'::jsonb
);
