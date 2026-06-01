package store

// PostgreSQL-backed implementation of the Store interface.
//
// PostgresStore provides persistent storage with proper transactional
// guarantees. It stores API key hashes (SHA-256) rather than raw keys,
// so even if the database is compromised, API keys cannot be recovered.
//
// Balance operations (Credit/Debit) use PostgreSQL transactions to ensure
// atomicity — the balance update and ledger entry are committed together
// or not at all. The Debit operation uses a conditional UPDATE that only
// succeeds if the balance is sufficient, preventing negative balances.
//
// Schema migrations run automatically on startup via the migrate() method.

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Compile-time check that PostgresStore implements Store.
var _ Store = (*PostgresStore)(nil)

// PostgresStore is a PostgreSQL-backed implementation of Store.
type PostgresStore struct {
	pool *pgxpool.Pool

	// In-memory cache for model prices. Keyed by "accountID:model".
	// Eliminates a DB round trip on every inference request for
	// platform pricing lookups (which change rarely).
	priceCacheMu sync.RWMutex
	priceCache   map[string]cachedPrice
}

type cachedPrice struct {
	input, output int64
	at            time.Time
}

// NewPostgres creates a new PostgresStore connected to the given database URL.
// It runs schema migrations on startup.
func NewPostgres(ctx context.Context, scfg Config) (*PostgresStore, error) {
	cfg, err := pgxpool.ParseConfig(scfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("store: parse postgres config: %w", err)
	}

	// Pool was previously capped at 20, causing connection starvation under
	// load. The stats endpoint holds connections for up to 10s (full-table
	// scans on usage), billing settlement takes 5-7 sequential operations,
	// and heartbeat upserts fire every 30s per provider. 20 connections is
	// exhausted by 3-4 concurrent inference completions + a single stats
	// cache miss.
	if cfg.MaxConns < 80 {
		cfg.MaxConns = 80
	}
	cfg.MinConns = 10
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.HealthCheckPeriod = 30 * time.Second

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: connect to postgres: %w", err)
	}

	// Verify connectivity.
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: ping postgres: %w", err)
	}

	s := &PostgresStore{
		pool:       pool,
		priceCache: make(map[string]cachedPrice),
	}
	if err := s.migrate(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: run migrations: %w", err)
	}

	return s, nil
}

// Close shuts down the connection pool.
func (s *PostgresStore) Close() {
	s.pool.Close()
}

// migrate runs the schema creation statements.
func (s *PostgresStore) migrate(ctx context.Context) error {
	migrations := []string{
		// schema_migrations records one-time data migrations that must run at most
		// once rather than on every boot. Idempotent DDL (CREATE/ALTER ... IF [NOT]
		// EXISTS) does not need this; it exists to gate destructive one-shot DML
		// cleanups (see the model_prices cleanup below) behind a marker id.
		`CREATE TABLE IF NOT EXISTS schema_migrations (
			id TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,

		`CREATE TABLE IF NOT EXISTS providers (
			id TEXT PRIMARY KEY,
			hardware JSONB NOT NULL,
			models JSONB NOT NULL,
			backend TEXT NOT NULL,
			location JSONB,
			registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			trust_level TEXT NOT NULL DEFAULT 'none',
			attested BOOLEAN NOT NULL DEFAULT FALSE,
			attestation_result JSONB,
			se_public_key TEXT NOT NULL DEFAULT '',
			serial_number TEXT NOT NULL DEFAULT '',
			mda_verified BOOLEAN NOT NULL DEFAULT FALSE,
			mda_cert_chain JSONB,
			acme_verified BOOLEAN NOT NULL DEFAULT FALSE,
			version TEXT NOT NULL DEFAULT '',
			runtime_verified BOOLEAN NOT NULL DEFAULT FALSE,
			python_hash TEXT NOT NULL DEFAULT '',
			runtime_hash TEXT NOT NULL DEFAULT '',
			last_challenge_verified TIMESTAMPTZ,
			failed_challenges INT NOT NULL DEFAULT 0,
			account_id TEXT NOT NULL DEFAULT '',
			lifetime_requests_served BIGINT NOT NULL DEFAULT 0,
			lifetime_tokens_generated BIGINT NOT NULL DEFAULT 0,
			last_session_requests_served BIGINT NOT NULL DEFAULT 0,
			last_session_tokens_generated BIGINT NOT NULL DEFAULT 0
		)`,
		// Migrate existing providers table: add new columns if upgrading from previous schema
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS location JSONB; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS trust_level TEXT NOT NULL DEFAULT 'none'; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS attested BOOLEAN NOT NULL DEFAULT FALSE; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS attestation_result JSONB; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS se_public_key TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS serial_number TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS mda_verified BOOLEAN NOT NULL DEFAULT FALSE; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS mda_cert_chain JSONB; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS acme_verified BOOLEAN NOT NULL DEFAULT FALSE; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS version TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS runtime_verified BOOLEAN NOT NULL DEFAULT FALSE; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS python_hash TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS runtime_hash TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_challenge_verified TIMESTAMPTZ; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS failed_challenges INT NOT NULL DEFAULT 0; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS account_id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS lifetime_requests_served BIGINT NOT NULL DEFAULT 0; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS lifetime_tokens_generated BIGINT NOT NULL DEFAULT 0; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_session_requests_served BIGINT NOT NULL DEFAULT 0; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_session_tokens_generated BIGINT NOT NULL DEFAULT 0; EXCEPTION WHEN others THEN NULL; END $$`,
		`CREATE INDEX IF NOT EXISTS idx_providers_serial ON providers(serial_number) WHERE serial_number != ''`,
		`CREATE INDEX IF NOT EXISTS idx_providers_account ON providers(account_id, last_seen DESC) WHERE account_id != ''`,

		// Migrate usage table: add request_id and cost columns
		`DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS request_id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS cost_micro_usd BIGINT NOT NULL DEFAULT 0; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS request_location JSONB; EXCEPTION WHEN others THEN NULL; END $$`,

		// Provider reputation — persistent reputation tracking
		`CREATE TABLE IF NOT EXISTS provider_reputation (
			provider_id TEXT PRIMARY KEY REFERENCES providers(id),
			total_jobs INT NOT NULL DEFAULT 0,
			successful_jobs INT NOT NULL DEFAULT 0,
			failed_jobs INT NOT NULL DEFAULT 0,
			total_uptime_seconds BIGINT NOT NULL DEFAULT 0,
			avg_response_time_ms BIGINT NOT NULL DEFAULT 0,
			challenges_passed INT NOT NULL DEFAULT 0,
			challenges_failed INT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS api_keys (
			key_hash TEXT PRIMARY KEY,
			raw_prefix TEXT NOT NULL,
			owner_account_id TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			active BOOLEAN NOT NULL DEFAULT TRUE
		)`,
		`DO $$ BEGIN
			ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS owner_account_id TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		// Multi-key support: per-key id, name, limits, expiry, last-used.
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS limit_micro_usd BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS limit_reset TEXT NOT NULL DEFAULT 'none'; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS rpm_limit BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS itpm_limit BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS otpm_limit BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS allowed_models TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ; EXCEPTION WHEN others THEN NULL; END $$`,
		// Backfill stable IDs for legacy rows (deterministic from the hash so
		// it is stable across restarts and idempotent).
		`UPDATE api_keys SET id = 'key_' || substr(md5(key_hash), 1, 24) WHERE id IS NULL OR id = ''`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_api_keys_id ON api_keys(id) WHERE id <> ''`,
		`CREATE INDEX IF NOT EXISTS idx_api_keys_owner ON api_keys(owner_account_id) WHERE owner_account_id <> ''`,
		`CREATE TABLE IF NOT EXISTS usage (
			id BIGSERIAL PRIMARY KEY,
			provider_id TEXT NOT NULL,
			consumer_key_hash TEXT NOT NULL,
			key_id TEXT NOT NULL DEFAULT '',
			model TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL,
			completion_tokens INTEGER NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			request_id TEXT NOT NULL DEFAULT '',
			cost_micro_usd BIGINT NOT NULL DEFAULT 0,
			request_location JSONB
		)`,
		// Per-key usage attribution — ALTER for DBs upgrading from a usage
		// table created before key_id existed. Must run AFTER CREATE TABLE usage.
		`DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS key_id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		// Indexes for usage queries (stats, billing, per-consumer history).
		`CREATE INDEX IF NOT EXISTS idx_usage_created ON usage(created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_consumer ON usage(consumer_key_hash, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage(provider_id, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_key ON usage(key_id, created_at DESC) WHERE key_id <> ''`,

		`CREATE TABLE IF NOT EXISTS payments (
			id BIGSERIAL PRIMARY KEY,
			tx_hash TEXT UNIQUE,
			consumer_address TEXT NOT NULL,
			provider_address TEXT NOT NULL,
			amount_usd TEXT NOT NULL,
			model TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL,
			completion_tokens INTEGER NOT NULL,
			memo TEXT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS balances (
			account_id TEXT PRIMARY KEY,
			balance_micro_usd BIGINT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS ledger_entries (
			id BIGSERIAL PRIMARY KEY,
			account_id TEXT NOT NULL,
			entry_type TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			balance_after BIGINT NOT NULL,
			reference TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_ledger_account ON ledger_entries(account_id, created_at DESC)`,

		// Referral system tables
		`CREATE TABLE IF NOT EXISTS referrers (
			account_id TEXT PRIMARY KEY,
			code TEXT UNIQUE NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referrers_code ON referrers(code)`,

		`CREATE TABLE IF NOT EXISTS referrals (
			referred_account TEXT PRIMARY KEY,
			referrer_code TEXT NOT NULL REFERENCES referrers(code),
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referrals_code ON referrals(referrer_code)`,

		// Billing sessions table
		`CREATE TABLE IF NOT EXISTS billing_sessions (
			id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			payment_method TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			external_id TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'pending',
			referral_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			completed_at TIMESTAMPTZ
		)`,
		`CREATE INDEX IF NOT EXISTS idx_billing_sessions_account ON billing_sessions(account_id)`,
		`CREATE INDEX IF NOT EXISTS idx_billing_sessions_external ON billing_sessions(external_id)`,
		`DO $$ BEGIN
			ALTER TABLE billing_sessions DROP COLUMN IF EXISTS chain;
		EXCEPTION WHEN others THEN NULL;
		END $$`,

		// Custom pricing — per-account model price overrides
		`CREATE TABLE IF NOT EXISTS model_prices (
			account_id TEXT NOT NULL,
			model TEXT NOT NULL,
			input_price BIGINT NOT NULL,
			output_price BIGINT NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (account_id, model)
		)`,

		// Clean up wallet-keyed custom prices: with the removal of wallet-based
		// payouts, model_prices rows keyed by Solana wallet addresses are
		// unreachable. Providers must re-enter custom prices under their Stripe
		// Connect account ID.
		//
		// This is a one-time, destructive cleanup, so it is gated on a
		// schema_migrations marker and runs at most once instead of on every boot.
		// Two further guards:
		//   - Exclude the synthetic "platform" account. Platform-default per-model
		//     pricing (set via PUT /v1/admin/pricing and at model registration) is
		//     stored under account_id='platform', which is NEVER a row in users.
		//     Without this guard the cleanup would wipe all platform pricing,
		//     silently reverting billing to the fallback defaults.
		//   - The marker is written only after a successful DELETE within the same
		//     block, so a run that errors (e.g. users not yet created on a brand-new
		//     DB) rolls back and is retried on the next boot.
		`DO $$ BEGIN
			IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE id = 'cleanup_wallet_model_prices_v1') THEN
				DELETE FROM model_prices
				WHERE account_id NOT IN (SELECT account_id FROM users)
				  AND account_id <> 'platform';
				INSERT INTO schema_migrations (id) VALUES ('cleanup_wallet_model_prices_v1');
			END IF;
		EXCEPTION WHEN others THEN NULL;
		END $$`,

		// Users — Privy identity → internal account mapping
		`CREATE TABLE IF NOT EXISTS users (
			account_id TEXT PRIMARY KEY,
			privy_user_id TEXT UNIQUE NOT NULL,
			email TEXT NOT NULL DEFAULT '',
			role TEXT NOT NULL DEFAULT '',
			platform_fee_percent BIGINT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`DO $$ BEGIN
			ALTER TABLE users ADD COLUMN IF NOT EXISTS email TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE users DROP COLUMN IF EXISTS solana_wallet_address;
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE users DROP COLUMN IF EXISTS solana_wallet_id;
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy ON users(privy_user_id)`,

		// The legacy admin-managed supported_models catalog was replaced by the
		// manifest-backed model_registry below. Drop the stale duplicate table if
		// it is still present from an older deployment.
		`DROP TABLE IF EXISTS supported_models`,

		`CREATE TABLE IF NOT EXISTS model_registry (
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
		)`,
		`CREATE INDEX IF NOT EXISTS idx_model_registry_status ON model_registry(status)`,
		`CREATE TABLE IF NOT EXISTS model_versions (
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
		)`,
		`DO $$ BEGIN
			ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS max_context_length INTEGER NOT NULL DEFAULT 0;
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS max_output_length INTEGER NOT NULL DEFAULT 0;
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS runtime_parameters JSONB NOT NULL DEFAULT '{}';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`CREATE INDEX IF NOT EXISTS idx_model_versions_model ON model_versions(model_id)`,
		`CREATE TABLE IF NOT EXISTS model_version_files (
			id BIGSERIAL PRIMARY KEY,
			model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE CASCADE,
			path TEXT NOT NULL,
			size_bytes BIGINT NOT NULL,
			sha256 TEXT NOT NULL,
			role TEXT NOT NULL,
			UNIQUE(model_version_id, path)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_model_version_files_version ON model_version_files(model_version_id)`,
		`CREATE TABLE IF NOT EXISTS model_active_versions (
			model_id TEXT PRIMARY KEY REFERENCES model_registry(id) ON DELETE CASCADE,
			model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE RESTRICT,
			activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS publishing_api_keys (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			key_hash TEXT NOT NULL,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_used_at TIMESTAMPTZ
		)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_api_keys_hash ON publishing_api_keys(key_hash)`,

		// Releases (provider binary versioning)
		`CREATE TABLE IF NOT EXISTS releases (
			version TEXT NOT NULL,
			platform TEXT NOT NULL,
			backend TEXT NOT NULL DEFAULT '',
			binary_hash TEXT NOT NULL DEFAULT '',
			bundle_hash TEXT NOT NULL DEFAULT '',
			metallib_hash TEXT NOT NULL DEFAULT '',
			python_hash TEXT NOT NULL DEFAULT '',
			runtime_hash TEXT NOT NULL DEFAULT '',
			template_hashes TEXT NOT NULL DEFAULT '',
			grpc_binary_hash TEXT NOT NULL DEFAULT '',
			url TEXT NOT NULL DEFAULT '',
			changelog TEXT NOT NULL DEFAULT '',
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (version, platform)
		)`,
		`DO $$ BEGIN
			ALTER TABLE releases ADD COLUMN IF NOT EXISTS backend TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE releases ADD COLUMN IF NOT EXISTS metallib_hash TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE releases ADD COLUMN IF NOT EXISTS changelog TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE releases ADD COLUMN IF NOT EXISTS python_hash TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE releases ADD COLUMN IF NOT EXISTS runtime_hash TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE releases ADD COLUMN IF NOT EXISTS template_hashes TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE releases ADD COLUMN IF NOT EXISTS grpc_binary_hash TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		// Drop deprecated image_bridge_hash column. Image generation is no longer
		// a first-class capability; the hash is meaningless. The DROP is wrapped
		// in a DO block so it's safe to re-run on databases that already lack it.
		`DO $$ BEGIN
			ALTER TABLE releases DROP COLUMN IF EXISTS image_bridge_hash;
		EXCEPTION WHEN others THEN NULL;
		END $$`,

		// Device authorization (RFC 8628-style)
		`CREATE TABLE IF NOT EXISTS device_codes (
			device_code TEXT PRIMARY KEY,
			user_code TEXT UNIQUE NOT NULL,
			account_id TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'pending',
			expires_at TIMESTAMPTZ NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_device_codes_user ON device_codes(user_code)`,

		// Provider tokens — long-lived auth linking provider machines to accounts
		`CREATE TABLE IF NOT EXISTS provider_tokens (
			token_hash TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			label TEXT NOT NULL DEFAULT '',
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_tokens_account ON provider_tokens(account_id)`,

		// Invite codes
		`CREATE TABLE IF NOT EXISTS invite_codes (
			code TEXT PRIMARY KEY,
			amount_micro_usd BIGINT NOT NULL,
			max_uses INTEGER NOT NULL DEFAULT 1,
			used_count INTEGER NOT NULL DEFAULT 0,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			expires_at TIMESTAMPTZ,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS invite_redemptions (
			code TEXT NOT NULL REFERENCES invite_codes(code),
			account_id TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (code, account_id)
		)`,

		// Provider earnings — per-node tracking
		`CREATE TABLE IF NOT EXISTS provider_earnings (
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
		)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_earnings_account ON provider_earnings(account_id, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_earnings_provider ON provider_earnings(provider_key, created_at DESC)`,

		// Materialized earnings summaries — atomically maintained by CreditProviderAccount.
		// Eliminates full-table SUM scans on /v1/provider/account-earnings.
		`CREATE TABLE IF NOT EXISTS earnings_summary (
			key TEXT NOT NULL,
			key_type TEXT NOT NULL,
			total_count BIGINT NOT NULL DEFAULT 0,
			total_micro_usd BIGINT NOT NULL DEFAULT 0,
			total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
			total_completion_tokens BIGINT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (key, key_type)
		)`,

		// Backfill earnings_summary from existing provider_earnings rows.
		// The INSERT ... ON CONFLICT DO NOTHING ensures this only runs once per key.
		`INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
		 SELECT account_id, 'account', COUNT(*), COALESCE(SUM(amount_micro_usd), 0),
		        COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0), NOW()
		 FROM provider_earnings
		 WHERE account_id != ''
		 GROUP BY account_id
		 ON CONFLICT (key, key_type) DO NOTHING`,

		`INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
		 SELECT provider_key, 'provider', COUNT(*), COALESCE(SUM(amount_micro_usd), 0),
		        COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0), NOW()
		 FROM provider_earnings
		 WHERE provider_key != ''
		 GROUP BY provider_key
		 ON CONFLICT (key, key_type) DO NOTHING`,

		// Provider payouts — wallet-based payout history for unlinked providers
		`CREATE TABLE IF NOT EXISTS provider_payouts (
			id BIGSERIAL PRIMARY KEY,
			provider_address TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			model TEXT NOT NULL DEFAULT '',
			job_id TEXT NOT NULL DEFAULT '',
			settled BOOLEAN NOT NULL DEFAULT FALSE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_payouts_address ON provider_payouts(provider_address, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_payouts_settled ON provider_payouts(settled, created_at DESC)`,

		// Stripe Connect — bank/card payouts
		`DO $$ BEGIN ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_account_id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_account_status TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_destination_type TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_destination_last4 TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_instant_eligible BOOLEAN NOT NULL DEFAULT FALSE; EXCEPTION WHEN others THEN NULL; END $$`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_stripe_account ON users(stripe_account_id) WHERE stripe_account_id != ''`,

		// Account role + per-account platform fee override (service accounts, e.g. OpenRouter).
		`DO $$ BEGIN ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE users ADD COLUMN IF NOT EXISTS platform_fee_percent BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,

		`CREATE TABLE IF NOT EXISTS stripe_withdrawals (
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
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_account ON stripe_withdrawals(account_id, created_at DESC)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_stripe_withdrawals_transfer ON stripe_withdrawals(transfer_id) WHERE transfer_id != ''`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_stripe_withdrawals_payout ON stripe_withdrawals(payout_id) WHERE payout_id != ''`,

		// Telemetry events table + indices removed.
		// Datadog is the sole durable sink for telemetry — the Postgres table
		// was the single largest source of DB write pressure under provider load
		// (60 providers × batch/10s × 50 rows × 5 indexes = ~30-40% of the
		// connection pool). No read endpoints consumed this table.',

		// Withdrawable balance — tracks the withdrawable subset of balance_micro_usd.
		`ALTER TABLE balances ADD COLUMN IF NOT EXISTS withdrawable_micro_usd BIGINT NOT NULL DEFAULT 0`,

		// Backfill withdrawable from ledger history: sum earnings minus
		// successful withdrawals. Idempotent — only updates rows where
		// withdrawable is still 0 (first deploy) so it won't overwrite
		// live values on restart.
		`UPDATE balances b SET withdrawable_micro_usd = GREATEST(0, COALESCE((
			SELECT SUM(amount_micro_usd) FROM ledger_entries
			WHERE account_id = b.account_id
			  AND entry_type IN ('payout', 'referral_reward', 'admin_reward', 'stripe_payout')
		), 0)) WHERE b.withdrawable_micro_usd = 0`,

		// Materialized usage totals — eliminates full-table scan of usage
		// on every stats cache miss.  Single counter row incremented
		// atomically by RecordUsage / RecordUsageWithCostAndLocation.
		`CREATE TABLE IF NOT EXISTS usage_totals (
			id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
			total_requests BIGINT NOT NULL DEFAULT 0,
			total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
			total_completion_tokens BIGINT NOT NULL DEFAULT 0
		)`,
		// Backfill from existing usage rows.  ON CONFLICT DO NOTHING makes
		// this idempotent — only runs on first deploy.
		`INSERT INTO usage_totals (id, total_requests, total_prompt_tokens, total_completion_tokens)
		 SELECT 1, COUNT(*), COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0)
		 FROM usage
		 ON CONFLICT (id) DO NOTHING`,

		// Partial index for UsageLocationBuckets — only rows with a
		// non-null request_location are ever queried.
		`CREATE INDEX IF NOT EXISTS idx_usage_request_location_notnull ON usage(created_at DESC) WHERE request_location IS NOT NULL`,

		// Provider log reports — providers upload 24h unified logs for debugging.
		`CREATE TABLE IF NOT EXISTS provider_log_reports (
			id BIGSERIAL PRIMARY KEY,
			serial_number TEXT NOT NULL,
			provider_id TEXT NOT NULL DEFAULT '',
			account_id TEXT NOT NULL DEFAULT '',
			log_data BYTEA NOT NULL,
			log_size_bytes BIGINT NOT NULL DEFAULT 0,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_log_reports_serial ON provider_log_reports(serial_number, created_at DESC)`,
	}

	for _, m := range migrations {
		if _, err := s.pool.Exec(ctx, m); err != nil {
			return fmt.Errorf("migration failed: %w", err)
		}
	}
	return nil
}
