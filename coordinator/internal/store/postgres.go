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
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Compile-time check that PostgresStore implements Store.
var _ Store = (*PostgresStore)(nil)

// PostgresStore is a PostgreSQL-backed implementation of Store.
type PostgresStore struct {
	pool *pgxpool.Pool
}

// NewPostgres creates a new PostgresStore connected to the given database URL.
// It runs schema migrations on startup.
func NewPostgres(ctx context.Context, connString string) (*PostgresStore, error) {
	cfg, err := pgxpool.ParseConfig(connString)
	if err != nil {
		return nil, fmt.Errorf("store: parse postgres config: %w", err)
	}

	if cfg.MaxConns < 20 {
		cfg.MaxConns = 20
	}
	cfg.MinConns = 5
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

	s := &PostgresStore{pool: pool}
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
		`CREATE TABLE IF NOT EXISTS providers (
			id TEXT PRIMARY KEY,
			hardware JSONB NOT NULL,
			models JSONB NOT NULL,
			backend TEXT NOT NULL,
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
		`CREATE TABLE IF NOT EXISTS usage (
			id BIGSERIAL PRIMARY KEY,
			provider_id TEXT NOT NULL,
			consumer_key_hash TEXT NOT NULL,
			model TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL,
			completion_tokens INTEGER NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			request_id TEXT NOT NULL DEFAULT '',
			cost_micro_usd BIGINT NOT NULL DEFAULT 0
		)`,
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
			chain TEXT NOT NULL DEFAULT '',
			amount_micro_usd BIGINT NOT NULL,
			external_id TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'pending',
			referral_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			completed_at TIMESTAMPTZ
		)`,
		`CREATE INDEX IF NOT EXISTS idx_billing_sessions_account ON billing_sessions(account_id)`,
		`CREATE INDEX IF NOT EXISTS idx_billing_sessions_external ON billing_sessions(external_id)`,

		// Enterprise invoicing — admin-managed postpaid accounts.
		`CREATE TABLE IF NOT EXISTS enterprise_accounts (
			account_id TEXT PRIMARY KEY,
			status TEXT NOT NULL DEFAULT 'active',
			billing_email TEXT NOT NULL DEFAULT '',
			stripe_customer_id TEXT NOT NULL DEFAULT '',
			cadence TEXT NOT NULL DEFAULT 'monthly',
			terms_days INTEGER NOT NULL DEFAULT 15,
			credit_limit_micro_usd BIGINT NOT NULL DEFAULT 0,
			accrued_micro_usd BIGINT NOT NULL DEFAULT 0,
			reserved_micro_usd BIGINT NOT NULL DEFAULT 0,
			open_invoice_micro_usd BIGINT NOT NULL DEFAULT 0,
			rounding_carry_micro_usd BIGINT NOT NULL DEFAULT 0,
			current_period_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			next_invoice_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_enterprise_due ON enterprise_accounts(status, next_invoice_at)`,
		`CREATE TABLE IF NOT EXISTS enterprise_reservations (
			request_id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL REFERENCES enterprise_accounts(account_id),
			amount_micro_usd BIGINT NOT NULL,
			actual_micro_usd BIGINT NOT NULL DEFAULT 0,
			status TEXT NOT NULL DEFAULT 'reserved',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_enterprise_reservations_account ON enterprise_reservations(account_id, created_at DESC)`,
		`CREATE TABLE IF NOT EXISTS enterprise_invoices (
			id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL REFERENCES enterprise_accounts(account_id),
			stripe_invoice_id TEXT NOT NULL DEFAULT '',
			stripe_hosted_invoice_url TEXT NOT NULL DEFAULT '',
			stripe_invoice_pdf TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'draft',
			period_start TIMESTAMPTZ NOT NULL,
			period_end TIMESTAMPTZ NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			amount_cents BIGINT NOT NULL,
			terms_days INTEGER NOT NULL,
			due_at TIMESTAMPTZ,
			sent_at TIMESTAMPTZ,
			paid_at TIMESTAMPTZ,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_enterprise_invoices_stripe ON enterprise_invoices(stripe_invoice_id) WHERE stripe_invoice_id != ''`,
		`CREATE INDEX IF NOT EXISTS idx_enterprise_invoices_account ON enterprise_invoices(account_id, created_at DESC)`,

		// Custom pricing — per-account model price overrides
		`CREATE TABLE IF NOT EXISTS model_prices (
			account_id TEXT NOT NULL,
			model TEXT NOT NULL,
			input_price BIGINT NOT NULL,
			output_price BIGINT NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (account_id, model)
		)`,

		// Users — Privy identity → internal account mapping
		`CREATE TABLE IF NOT EXISTS users (
			account_id TEXT PRIMARY KEY,
			privy_user_id TEXT UNIQUE NOT NULL,
			email TEXT NOT NULL DEFAULT '',
			solana_wallet_address TEXT NOT NULL DEFAULT '',
			solana_wallet_id TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`DO $$ BEGIN
			ALTER TABLE users ADD COLUMN IF NOT EXISTS email TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy ON users(privy_user_id)`,

		// Supported models — admin-managed catalog
		`CREATE TABLE IF NOT EXISTS supported_models (
			id TEXT PRIMARY KEY,
			s3_name TEXT NOT NULL DEFAULT '',
			display_name TEXT NOT NULL DEFAULT '',
			model_type TEXT NOT NULL DEFAULT 'text',
			size_gb DOUBLE PRECISION NOT NULL DEFAULT 0,
			architecture TEXT NOT NULL DEFAULT '',
			description TEXT NOT NULL DEFAULT '',
			min_ram_gb INTEGER NOT NULL DEFAULT 0,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		// Add model_type column if upgrading from previous schema
		`DO $$ BEGIN
			ALTER TABLE supported_models ADD COLUMN IF NOT EXISTS model_type TEXT NOT NULL DEFAULT 'text';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		// Add weight_hash column for model integrity verification
		`DO $$ BEGIN
			ALTER TABLE supported_models ADD COLUMN IF NOT EXISTS weight_hash TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,

		// Releases (provider binary versioning)
		`CREATE TABLE IF NOT EXISTS releases (
			version TEXT NOT NULL,
			platform TEXT NOT NULL,
			binary_hash TEXT NOT NULL DEFAULT '',
			bundle_hash TEXT NOT NULL DEFAULT '',
			python_hash TEXT NOT NULL DEFAULT '',
			runtime_hash TEXT NOT NULL DEFAULT '',
			template_hashes TEXT NOT NULL DEFAULT '',
			grpc_binary_hash TEXT NOT NULL DEFAULT '',
			image_bridge_hash TEXT NOT NULL DEFAULT '',
			url TEXT NOT NULL DEFAULT '',
			changelog TEXT NOT NULL DEFAULT '',
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (version, platform)
		)`,
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
		`DO $$ BEGIN
			ALTER TABLE releases ADD COLUMN IF NOT EXISTS image_bridge_hash TEXT NOT NULL DEFAULT '';
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

		// Telemetry events — production observability table.
		`CREATE TABLE IF NOT EXISTS telemetry_events (
			id UUID PRIMARY KEY,
			ts TIMESTAMPTZ NOT NULL,
			source TEXT NOT NULL,
			severity TEXT NOT NULL,
			kind TEXT NOT NULL,
			version TEXT NOT NULL DEFAULT '',
			machine_id TEXT NOT NULL DEFAULT '',
			account_id TEXT NOT NULL DEFAULT '',
			request_id TEXT NOT NULL DEFAULT '',
			session_id TEXT NOT NULL DEFAULT '',
			message TEXT NOT NULL,
			fields JSONB NOT NULL DEFAULT '{}'::jsonb,
			stack TEXT NOT NULL DEFAULT '',
			received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_telemetry_ts ON telemetry_events(ts DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_telemetry_source_sev ON telemetry_events(source, severity, ts DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_telemetry_kind ON telemetry_events(kind, ts DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_telemetry_machine ON telemetry_events(machine_id, ts DESC) WHERE machine_id != ''`,
		`CREATE INDEX IF NOT EXISTS idx_telemetry_request ON telemetry_events(request_id) WHERE request_id != ''`,

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
	}

	for _, m := range migrations {
		if _, err := s.pool.Exec(ctx, m); err != nil {
			return fmt.Errorf("migration failed: %w", err)
		}
	}
	return nil
}

// hashKey returns the SHA-256 hex digest of the given API key.
func hashKey(key string) string {
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:])
}

// keyPrefix returns the first 12 characters of a key for display purposes.
func keyPrefix(key string) string {
	if len(key) <= 12 {
		return key
	}
	return key[:12] + "..."
}

// CreateKey generates a cryptographically random API key, hashes it, stores
// the hash, and returns the raw key (the only time it's available in plaintext).
func (s *PostgresStore) CreateKey() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("store: generate key: %w", err)
	}
	raw := "eigeninference-" + hex.EncodeToString(b)
	h := hashKey(raw)
	prefix := keyPrefix(raw)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO api_keys (key_hash, raw_prefix) VALUES ($1, $2)`,
		h, prefix,
	)
	if err != nil {
		return "", fmt.Errorf("store: insert key: %w", err)
	}

	return raw, nil
}

// SeedKey inserts a specific raw key into the database. This is used for
// bootstrapping the admin key. If the key already exists, it is a no-op.
func (s *PostgresStore) SeedKey(rawKey string) error {
	h := hashKey(rawKey)
	prefix := keyPrefix(rawKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO api_keys (key_hash, raw_prefix) VALUES ($1, $2)
		 ON CONFLICT (key_hash) DO NOTHING`,
		h, prefix,
	)
	if err != nil {
		return fmt.Errorf("store: seed key: %w", err)
	}
	return nil
}

// CreateKeyForAccount generates a new API key linked to a specific account.
func (s *PostgresStore) CreateKeyForAccount(accountID string) (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("store: generate key: %w", err)
	}
	raw := "eigeninference-" + hex.EncodeToString(b)
	h := hashKey(raw)
	prefix := keyPrefix(raw)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO api_keys (key_hash, raw_prefix, owner_account_id) VALUES ($1, $2, $3)`,
		h, prefix, accountID,
	)
	if err != nil {
		return "", fmt.Errorf("store: insert key: %w", err)
	}
	return raw, nil
}

// GetKeyAccount returns the account ID that owns this key, or "" if unlinked.
func (s *PostgresStore) GetKeyAccount(key string) string {
	h := hashKey(key)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var accountID string
	err := s.pool.QueryRow(ctx,
		`SELECT owner_account_id FROM api_keys WHERE key_hash = $1 AND active = TRUE`, h,
	).Scan(&accountID)
	if err != nil {
		return ""
	}
	return accountID
}

// ValidateKey returns true if the given key exists and is active.
func (s *PostgresStore) ValidateKey(key string) bool {
	h := hashKey(key)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var active bool
	err := s.pool.QueryRow(ctx,
		`SELECT active FROM api_keys WHERE key_hash = $1`,
		h,
	).Scan(&active)
	if err != nil {
		return false
	}
	return active
}

// RevokeKey deactivates a key. Returns true if the key existed and was active.
func (s *PostgresStore) RevokeKey(key string) bool {
	h := hashKey(key)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE api_keys SET active = FALSE WHERE key_hash = $1 AND active = TRUE`,
		h,
	)
	if err != nil {
		return false
	}
	return tag.RowsAffected() > 0
}

// RecordUsage inserts a usage record into PostgreSQL.
func (s *PostgresStore) RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int) {
	h := hashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, _ = s.pool.Exec(ctx,
		`INSERT INTO usage (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens)
		 VALUES ($1, $2, $3, $4, $5)`,
		providerID, h, model, promptTokens, completionTokens,
	)
}

// UsageByConsumer returns usage records for a specific consumer key.
func (s *PostgresStore) UsageByConsumer(consumerKey string) []UsageRecord {
	h := hashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens, created_at, request_id, cost_micro_usd
		 FROM usage WHERE consumer_key_hash = $1 ORDER BY created_at DESC LIMIT 100`, h)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		if err := rows.Scan(&r.ProviderID, &r.ConsumerKey, &r.Model, &r.PromptTokens, &r.CompletionTokens, &r.CreatedAt, &r.RequestID, &r.CostMicroUSD); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}

// RecordUsageWithCost inserts a usage record with request ID and cost.
func (s *PostgresStore) RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64) {
	h := hashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, _ = s.pool.Exec(ctx,
		`INSERT INTO usage (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens, request_id, cost_micro_usd)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		providerID, h, model, promptTokens, completionTokens, requestID, costMicroUSD,
	)
}

// RecordPayment inserts a payment record into PostgreSQL.
func (s *PostgresStore) RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO payments (tx_hash, consumer_address, provider_address, amount_usd, model, prompt_tokens, completion_tokens, memo)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		txHash, consumerAddr, providerAddr, amountUSD, model, promptTokens, completionTokens, memo,
	)
	if err != nil {
		return fmt.Errorf("store: insert payment: %w", err)
	}
	return nil
}

// UsageTotals returns aggregated lifetime totals from the usage table.
// Uses SQL aggregation to avoid shipping every row over the wire.
func (s *PostgresStore) UsageTotals() UsageTotals {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var t UsageTotals
	_ = s.pool.QueryRow(ctx,
		`SELECT COUNT(*),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM usage`,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens)
	return t
}

// UsageTimeSeries returns per-minute usage buckets at or after `since`.
func (s *PostgresStore) UsageTimeSeries(since time.Time) []UsageBucket {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT date_trunc('minute', created_at) AS minute,
		        COUNT(*),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM usage
		 WHERE created_at >= $1
		 GROUP BY minute
		 ORDER BY minute ASC`,
		since,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var buckets []UsageBucket
	for rows.Next() {
		var b UsageBucket
		if err := rows.Scan(&b.Minute, &b.Requests, &b.PromptTokens, &b.CompletionTokens); err != nil {
			continue
		}
		buckets = append(buckets, b)
	}
	return buckets
}

// Leaderboard returns the top N accounts ranked by the given metric over the
// given time window. Zero `since` means all-time. The ranking is computed in
// SQL via aggregation on provider_earnings — no per-row wire transfer.
func (s *PostgresStore) Leaderboard(metric LeaderboardMetric, since time.Time, limit int) []LeaderboardRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if limit <= 0 || limit > 200 {
		limit = 50
	}

	orderBy := "earnings_micro_usd DESC"
	switch metric {
	case LeaderboardTokens:
		orderBy = "tokens DESC"
	case LeaderboardJobs:
		orderBy = "jobs DESC"
	}

	// account_id != '' filters out unassigned earnings (e.g. legacy wallet-only).
	q := `SELECT account_id,
	             COALESCE(SUM(amount_micro_usd), 0)               AS earnings_micro_usd,
	             COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS tokens,
	             COUNT(*)                                          AS jobs
	      FROM provider_earnings
	      WHERE account_id != ''`
	args := []any{}
	if !since.IsZero() {
		q += ` AND created_at >= $1`
		args = append(args, since)
	}
	q += `
	      GROUP BY account_id
	      ORDER BY ` + orderBy + `
	      LIMIT $` + strconv.Itoa(len(args)+1)
	args = append(args, limit)

	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()

	out := make([]LeaderboardRow, 0, limit)
	for rows.Next() {
		var r LeaderboardRow
		if err := rows.Scan(&r.AccountID, &r.EarningsMicroUSD, &r.Tokens, &r.Jobs); err != nil {
			continue
		}
		out = append(out, r)
	}
	return out
}

// NetworkTotals returns aggregated metrics across all earnings for the given
// time window. Zero `since` means all-time.
func (s *PostgresStore) NetworkTotals(since time.Time) NetworkTotalsRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	q := `SELECT COALESCE(SUM(amount_micro_usd), 0),
	             COALESCE(SUM(prompt_tokens + completion_tokens), 0),
	             COUNT(*),
	             COUNT(DISTINCT account_id) FILTER (WHERE account_id != '')
	      FROM provider_earnings`
	args := []any{}
	if !since.IsZero() {
		q += ` WHERE created_at >= $1`
		args = append(args, since)
	}

	var t NetworkTotalsRow
	_ = s.pool.QueryRow(ctx, q, args...).
		Scan(&t.EarningsMicroUSD, &t.Tokens, &t.Jobs, &t.ActiveAccounts)
	return t
}

// UsageRecords returns all usage records from the database, ordered by creation time.
func (s *PostgresStore) UsageRecords() []UsageRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens, created_at
		 FROM usage ORDER BY created_at ASC`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		if err := rows.Scan(&r.ProviderID, &r.ConsumerKey, &r.Model, &r.PromptTokens, &r.CompletionTokens, &r.Timestamp); err != nil {
			continue
		}
		records = append(records, r)
	}
	if records == nil {
		records = make([]UsageRecord, 0)
	}
	return records
}

// GetBalance returns the current balance in micro-USD for an account.
func (s *PostgresStore) GetBalance(accountID string) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var balance int64
	err := s.pool.QueryRow(ctx,
		`SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balance)
	if err != nil {
		return 0
	}
	return balance
}

func nullableCreatedAt(ts time.Time) any {
	if ts.IsZero() {
		return nil
	}
	return ts
}

func creditTx(ctx context.Context, tx pgx.Tx, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, createdAt time.Time) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO balances (account_id, balance_micro_usd, updated_at)
		 VALUES ($1, $2, NOW())
		 ON CONFLICT (account_id) DO UPDATE SET
		   balance_micro_usd = balances.balance_micro_usd + $2,
		   updated_at = NOW()`,
		accountID, amountMicroUSD,
	)
	if err != nil {
		return fmt.Errorf("store: credit balance: %w", err)
	}

	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balanceAfter)
	if err != nil {
		return fmt.Errorf("store: read balance: %w", err)
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		accountID, string(entryType), amountMicroUSD, balanceAfter, reference, nullableCreatedAt(createdAt),
	)
	if err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	return nil
}

func creditWithdrawableTx(ctx context.Context, tx pgx.Tx, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, createdAt time.Time) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
		 VALUES ($1, $2, $2, NOW())
		 ON CONFLICT (account_id) DO UPDATE SET
		   balance_micro_usd = balances.balance_micro_usd + $2,
		   withdrawable_micro_usd = balances.withdrawable_micro_usd + $2,
		   updated_at = NOW()`,
		accountID, amountMicroUSD,
	)
	if err != nil {
		return fmt.Errorf("store: credit withdrawable balance: %w", err)
	}

	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balanceAfter)
	if err != nil {
		return fmt.Errorf("store: read balance: %w", err)
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		accountID, string(entryType), amountMicroUSD, balanceAfter, reference, nullableCreatedAt(createdAt),
	)
	if err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	return nil
}

// Credit adds micro-USD to an account and records a ledger entry (atomic).
func (s *PostgresStore) Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := creditTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// GetWithdrawableBalance returns the withdrawable balance in micro-USD.
func (s *PostgresStore) GetWithdrawableBalance(accountID string) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var balance int64
	err := s.pool.QueryRow(ctx,
		`SELECT withdrawable_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balance)
	if err != nil {
		return 0
	}
	return balance
}

// CreditWithdrawable adds micro-USD to both the total balance and the
// withdrawable balance, and records a ledger entry.
func (s *PostgresStore) CreditWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := creditWithdrawableTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
func (s *PostgresStore) Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Check and update balance atomically
	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`UPDATE balances
		 SET balance_micro_usd = balance_micro_usd - $2, updated_at = NOW()
		 WHERE account_id = $1 AND balance_micro_usd >= $2
		 RETURNING balance_micro_usd`,
		accountID, amountMicroUSD,
	).Scan(&balanceAfter)
	if err != nil {
		return errors.New("insufficient balance or account not found")
	}

	// Cap withdrawable at the new balance (credits consumed first).
	_, _ = tx.Exec(ctx,
		`UPDATE balances SET withdrawable_micro_usd = LEAST(withdrawable_micro_usd, balance_micro_usd)
		 WHERE account_id = $1`,
		accountID,
	)

	// Record ledger entry
	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, $5)`,
		accountID, string(entryType), -amountMicroUSD, balanceAfter, reference,
	)
	if err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	return tx.Commit(ctx)
}

// DebitWithdrawable subtracts micro-USD from both the total balance and the
// withdrawable balance atomically. Returns error if the withdrawable balance
// is insufficient. This ensures withdrawal debits are symmetric with
// CreditWithdrawable refunds — both touch the same columns.
func (s *PostgresStore) DebitWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`UPDATE balances
		 SET balance_micro_usd = balance_micro_usd - $2,
		     withdrawable_micro_usd = withdrawable_micro_usd - $2,
		     updated_at = NOW()
		 WHERE account_id = $1
		   AND balance_micro_usd >= $2
		   AND withdrawable_micro_usd >= $2
		 RETURNING balance_micro_usd`,
		accountID, amountMicroUSD,
	).Scan(&balanceAfter)
	if err != nil {
		return errors.New("insufficient withdrawable balance or account not found")
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, $5)`,
		accountID, string(entryType), -amountMicroUSD, balanceAfter, reference,
	)
	if err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	return tx.Commit(ctx)
}

// LedgerHistory returns ledger entries for an account, newest first.
func (s *PostgresStore) LedgerHistory(accountID string) []LedgerEntry {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Cap at 500 most-recent entries. Older history isn't shown on any
	// dashboard and was responsible for sending tens of thousands of rows
	// per request to high-volume accounts.
	rows, err := s.pool.Query(ctx,
		`SELECT id, account_id, entry_type, amount_micro_usd, balance_after, reference, created_at
		 FROM ledger_entries WHERE account_id = $1 ORDER BY created_at DESC LIMIT 500`,
		accountID,
	)
	if err != nil {
		return []LedgerEntry{}
	}
	defer rows.Close()

	var entries []LedgerEntry
	for rows.Next() {
		var e LedgerEntry
		var entryType string
		if err := rows.Scan(&e.ID, &e.AccountID, &entryType, &e.AmountMicroUSD, &e.BalanceAfter, &e.Reference, &e.CreatedAt); err != nil {
			continue
		}
		e.Type = LedgerEntryType(entryType)
		entries = append(entries, e)
	}
	if entries == nil {
		return []LedgerEntry{}
	}
	return entries
}

// KeyCount returns the number of active API keys.
func (s *PostgresStore) KeyCount() int {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var count int
	err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM api_keys WHERE active = TRUE`,
	).Scan(&count)
	if err != nil {
		return 0
	}
	return count
}

// --- Referral System ---

// CreateReferrer registers an account as a referrer with the given code.
func (s *PostgresStore) CreateReferrer(accountID, code string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO referrers (account_id, code) VALUES ($1, $2)`,
		accountID, code,
	)
	if err != nil {
		return fmt.Errorf("store: create referrer: %w", err)
	}
	return nil
}

// GetReferrerByCode returns the referrer for a given referral code.
func (s *PostgresStore) GetReferrerByCode(code string) (*Referrer, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var ref Referrer
	err := s.pool.QueryRow(ctx,
		`SELECT account_id, code, created_at FROM referrers WHERE code = $1`, code,
	).Scan(&ref.AccountID, &ref.Code, &ref.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: referrer not found: %w", err)
	}
	return &ref, nil
}

// GetReferrerByAccount returns the referrer record for an account.
func (s *PostgresStore) GetReferrerByAccount(accountID string) (*Referrer, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var ref Referrer
	err := s.pool.QueryRow(ctx,
		`SELECT account_id, code, created_at FROM referrers WHERE account_id = $1`, accountID,
	).Scan(&ref.AccountID, &ref.Code, &ref.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: referrer not found: %w", err)
	}
	return &ref, nil
}

// RecordReferral records that referredAccountID was referred by referrerCode.
func (s *PostgresStore) RecordReferral(referrerCode, referredAccountID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO referrals (referred_account, referrer_code) VALUES ($1, $2)`,
		referredAccountID, referrerCode,
	)
	if err != nil {
		return fmt.Errorf("store: record referral: %w", err)
	}
	return nil
}

// GetReferrerForAccount returns the referrer code that referred this account.
func (s *PostgresStore) GetReferrerForAccount(accountID string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var code string
	err := s.pool.QueryRow(ctx,
		`SELECT referrer_code FROM referrals WHERE referred_account = $1`, accountID,
	).Scan(&code)
	if err != nil {
		return "", nil // no referrer is not an error
	}
	return code, nil
}

// GetReferralStats returns referral statistics for a code.
func (s *PostgresStore) GetReferralStats(code string) (*ReferralStats, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Verify code exists
	var accountID string
	err := s.pool.QueryRow(ctx,
		`SELECT account_id FROM referrers WHERE code = $1`, code,
	).Scan(&accountID)
	if err != nil {
		return nil, fmt.Errorf("store: referral code not found: %w", err)
	}

	// Count referred accounts
	var totalReferred int
	_ = s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM referrals WHERE referrer_code = $1`, code,
	).Scan(&totalReferred)

	// Sum referral rewards from ledger
	var totalRewards int64
	_ = s.pool.QueryRow(ctx,
		`SELECT COALESCE(SUM(amount_micro_usd), 0) FROM ledger_entries
		 WHERE account_id = $1 AND entry_type = $2`,
		accountID, string(LedgerReferralReward),
	).Scan(&totalRewards)

	return &ReferralStats{
		Code:                 code,
		TotalReferred:        totalReferred,
		TotalRewardsMicroUSD: totalRewards,
	}, nil
}

// --- Billing Sessions ---

// CreateBillingSession stores a new billing session.
func (s *PostgresStore) CreateBillingSession(session *BillingSession) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO billing_sessions (id, account_id, payment_method, chain, amount_micro_usd, external_id, status, referral_code)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		session.ID, session.AccountID, session.PaymentMethod, session.Chain,
		session.AmountMicroUSD, session.ExternalID, session.Status, session.ReferralCode,
	)
	if err != nil {
		return fmt.Errorf("store: create billing session: %w", err)
	}
	return nil
}

// GetBillingSession retrieves a billing session by ID.
func (s *PostgresStore) GetBillingSession(sessionID string) (*BillingSession, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var bs BillingSession
	err := s.pool.QueryRow(ctx,
		`SELECT id, account_id, payment_method, chain, amount_micro_usd, external_id, status, referral_code, created_at, completed_at
		 FROM billing_sessions WHERE id = $1`, sessionID,
	).Scan(&bs.ID, &bs.AccountID, &bs.PaymentMethod, &bs.Chain,
		&bs.AmountMicroUSD, &bs.ExternalID, &bs.Status, &bs.ReferralCode,
		&bs.CreatedAt, &bs.CompletedAt)
	if err != nil {
		return nil, fmt.Errorf("store: billing session not found: %w", err)
	}
	return &bs, nil
}

// CompleteBillingSession marks a session as completed.
func (s *PostgresStore) CompleteBillingSession(sessionID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE billing_sessions SET status = 'completed', completed_at = NOW()
		 WHERE id = $1 AND status = 'pending'`, sessionID,
	)
	if err != nil {
		return fmt.Errorf("store: complete billing session: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("store: billing session %q not found or already completed", sessionID)
	}
	return nil
}

// IsExternalIDProcessed returns true if a completed billing session with this external ID exists.
func (s *PostgresStore) IsExternalIDProcessed(externalID string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var count int
	_ = s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM billing_sessions WHERE external_id = $1 AND status = 'completed'`,
		externalID,
	).Scan(&count)
	return count > 0
}

// --- Enterprise Invoicing ---

func (s *PostgresStore) UpsertEnterpriseAccount(account *EnterpriseAccount) error {
	if account == nil || account.AccountID == "" {
		return errors.New("enterprise account_id is required")
	}
	if account.CreditLimitMicroUSD < 0 ||
		account.AccruedMicroUSD < 0 ||
		account.ReservedMicroUSD < 0 ||
		account.OpenInvoiceMicroUSD < 0 ||
		account.RoundingCarryMicroUSD < 0 {
		return errors.New("enterprise money fields cannot be negative")
	}
	now := time.Now()
	if account.Status == "" {
		account.Status = EnterpriseStatusActive
	}
	if account.Cadence == "" {
		account.Cadence = EnterpriseCadenceMonthly
	}
	if account.CurrentPeriodStart.IsZero() {
		account.CurrentPeriodStart = now
	}
	if account.NextInvoiceAt.IsZero() {
		account.NextInvoiceAt = nextEnterpriseInvoiceAt(account.CurrentPeriodStart, account.Cadence)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx, `INSERT INTO enterprise_accounts (
			account_id, status, billing_email, stripe_customer_id, cadence, terms_days,
			credit_limit_micro_usd, accrued_micro_usd, reserved_micro_usd,
			open_invoice_micro_usd, rounding_carry_micro_usd,
			current_period_start, next_invoice_at, updated_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,NOW())
		ON CONFLICT (account_id) DO UPDATE SET
			status = EXCLUDED.status,
			billing_email = EXCLUDED.billing_email,
			stripe_customer_id = EXCLUDED.stripe_customer_id,
			cadence = EXCLUDED.cadence,
			terms_days = EXCLUDED.terms_days,
			credit_limit_micro_usd = EXCLUDED.credit_limit_micro_usd,
			accrued_micro_usd = EXCLUDED.accrued_micro_usd,
			reserved_micro_usd = EXCLUDED.reserved_micro_usd,
			open_invoice_micro_usd = EXCLUDED.open_invoice_micro_usd,
			rounding_carry_micro_usd = EXCLUDED.rounding_carry_micro_usd,
			current_period_start = EXCLUDED.current_period_start,
			next_invoice_at = EXCLUDED.next_invoice_at,
			updated_at = NOW()`,
		account.AccountID, account.Status, account.BillingEmail, account.StripeCustomerID,
		account.Cadence, account.TermsDays, account.CreditLimitMicroUSD, account.AccruedMicroUSD,
		account.ReservedMicroUSD, account.OpenInvoiceMicroUSD, account.RoundingCarryMicroUSD,
		account.CurrentPeriodStart, account.NextInvoiceAt)
	if err != nil {
		return fmt.Errorf("store: upsert enterprise account: %w", err)
	}
	return nil
}

const enterpriseAccountColumns = `account_id, status, billing_email, stripe_customer_id,
	cadence, terms_days, credit_limit_micro_usd, accrued_micro_usd, reserved_micro_usd,
	open_invoice_micro_usd, rounding_carry_micro_usd, current_period_start,
	next_invoice_at, created_at, updated_at`

func scanEnterpriseAccount(row interface{ Scan(...any) error }) (*EnterpriseAccount, error) {
	var a EnterpriseAccount
	if err := row.Scan(&a.AccountID, &a.Status, &a.BillingEmail, &a.StripeCustomerID,
		&a.Cadence, &a.TermsDays, &a.CreditLimitMicroUSD, &a.AccruedMicroUSD,
		&a.ReservedMicroUSD, &a.OpenInvoiceMicroUSD, &a.RoundingCarryMicroUSD,
		&a.CurrentPeriodStart, &a.NextInvoiceAt, &a.CreatedAt, &a.UpdatedAt); err != nil {
		return nil, err
	}
	return &a, nil
}

func (s *PostgresStore) GetEnterpriseAccount(accountID string) (*EnterpriseAccount, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx, `SELECT `+enterpriseAccountColumns+` FROM enterprise_accounts WHERE account_id = $1`, accountID)
	a, err := scanEnterpriseAccount(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("%w: %q", ErrEnterpriseAccountNotFound, accountID)
		}
		return nil, fmt.Errorf("store: enterprise account not found: %w", err)
	}
	return a, nil
}

func (s *PostgresStore) ListEnterpriseAccounts() ([]EnterpriseAccount, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx, `SELECT `+enterpriseAccountColumns+` FROM enterprise_accounts ORDER BY updated_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("store: list enterprise accounts: %w", err)
	}
	defer rows.Close()

	var out []EnterpriseAccount
	for rows.Next() {
		a, err := scanEnterpriseAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan enterprise account: %w", err)
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

func (s *PostgresStore) SetEnterpriseStripeCustomerID(accountID, stripeCustomerID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx, `UPDATE enterprise_accounts
		SET stripe_customer_id = $2, updated_at = NOW()
		WHERE account_id = $1`, accountID, stripeCustomerID)
	if err != nil {
		return fmt.Errorf("store: set enterprise stripe customer: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("enterprise account %q not found", accountID)
	}
	return nil
}

func (s *PostgresStore) AdvanceEnterpriseInvoicePeriod(accountID string, periodStart, nextInvoiceAt time.Time) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx, `UPDATE enterprise_accounts
		SET current_period_start = $2, next_invoice_at = $3, updated_at = NOW()
		WHERE account_id = $1`, accountID, periodStart, nextInvoiceAt)
	if err != nil {
		return fmt.Errorf("store: advance enterprise invoice period: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("enterprise account %q not found", accountID)
	}
	return nil
}

func (s *PostgresStore) ReserveEnterpriseUsage(accountID, requestID string, amountMicroUSD int64) error {
	if amountMicroUSD <= 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin enterprise reserve: %w", err)
	}
	defer tx.Rollback(ctx)

	var existingAccountID, existingStatus string
	err = tx.QueryRow(ctx, `SELECT account_id, status FROM enterprise_reservations WHERE request_id = $1 FOR UPDATE`, requestID).Scan(&existingAccountID, &existingStatus)
	if err == nil {
		if existingAccountID == accountID && existingStatus == "reserved" {
			var existingAmount int64
			if amountErr := tx.QueryRow(ctx, `SELECT amount_micro_usd FROM enterprise_reservations WHERE request_id = $1`, requestID).Scan(&existingAmount); amountErr != nil {
				return fmt.Errorf("store: check enterprise reservation amount: %w", amountErr)
			}
			if existingAmount != amountMicroUSD {
				return fmt.Errorf("enterprise reservation %q amount mismatch", requestID)
			}
			return tx.Commit(ctx)
		}
		if existingAccountID != accountID {
			return fmt.Errorf("enterprise reservation %q belongs to another account", requestID)
		}
		return fmt.Errorf("enterprise reservation %q already %s", requestID, existingStatus)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("store: check enterprise reservation: %w", err)
	}

	tag, err := tx.Exec(ctx, `UPDATE enterprise_accounts
		SET reserved_micro_usd = reserved_micro_usd + $2, updated_at = NOW()
		WHERE account_id = $1
			AND status = 'active'
			AND open_invoice_micro_usd + accrued_micro_usd + reserved_micro_usd + rounding_carry_micro_usd + $2 <= credit_limit_micro_usd`,
		accountID, amountMicroUSD)
	if err != nil {
		return fmt.Errorf("store: reserve enterprise usage: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("enterprise credit limit exceeded")
	}

	_, err = tx.Exec(ctx, `INSERT INTO enterprise_reservations
		(request_id, account_id, amount_micro_usd, status)
		VALUES ($1, $2, $3, 'reserved')`,
		requestID, accountID, amountMicroUSD)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			_ = tx.Rollback(ctx)
			var existingAccountID, status string
			checkErr := s.pool.QueryRow(ctx, `SELECT account_id, status FROM enterprise_reservations WHERE request_id = $1`, requestID).Scan(&existingAccountID, &status)
			if checkErr == nil && existingAccountID == accountID && status == "reserved" {
				return nil
			}
			if checkErr == nil && existingAccountID != accountID {
				return fmt.Errorf("enterprise reservation %q belongs to another account", requestID)
			}
			if checkErr == nil {
				return fmt.Errorf("enterprise reservation %q already %s", requestID, status)
			}
		}
		return fmt.Errorf("store: create enterprise reservation: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit enterprise reserve: %w", err)
	}
	return nil
}

func (s *PostgresStore) FinalizeEnterpriseUsage(accountID, requestID string, actualMicroUSD int64) error {
	if actualMicroUSD < 0 {
		actualMicroUSD = 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin enterprise finalize: %w", err)
	}
	defer tx.Rollback(ctx)

	var reserved int64
	err = tx.QueryRow(ctx, `UPDATE enterprise_reservations
		SET status = 'finalized', actual_micro_usd = LEAST($3, amount_micro_usd), updated_at = NOW()
		WHERE request_id = $1 AND account_id = $2 AND status = 'reserved'
		RETURNING amount_micro_usd`, requestID, accountID, actualMicroUSD).Scan(&reserved)
	if err != nil {
		return fmt.Errorf("store: finalize enterprise reservation: %w", err)
	}
	_, err = tx.Exec(ctx, `UPDATE enterprise_accounts
		SET reserved_micro_usd = GREATEST(reserved_micro_usd - $2, 0),
			accrued_micro_usd = accrued_micro_usd + LEAST($3, $2),
			updated_at = NOW()
		WHERE account_id = $1`, accountID, reserved, actualMicroUSD)
	if err != nil {
		return fmt.Errorf("store: accrue enterprise usage: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit enterprise finalize: %w", err)
	}
	return nil
}

func (s *PostgresStore) ReleaseEnterpriseReservation(accountID, requestID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin enterprise release: %w", err)
	}
	defer tx.Rollback(ctx)

	var reserved int64
	err = tx.QueryRow(ctx, `UPDATE enterprise_reservations
		SET status = 'released', updated_at = NOW()
		WHERE request_id = $1 AND account_id = $2 AND status = 'reserved'
		RETURNING amount_micro_usd`, requestID, accountID).Scan(&reserved)
	if errors.Is(err, pgx.ErrNoRows) {
		return tx.Commit(ctx)
	}
	if err != nil {
		return fmt.Errorf("store: release enterprise reservation: %w", err)
	}
	_, err = tx.Exec(ctx, `UPDATE enterprise_accounts
		SET reserved_micro_usd = GREATEST(reserved_micro_usd - $2, 0), updated_at = NOW()
		WHERE account_id = $1`, accountID, reserved)
	if err != nil {
		return fmt.Errorf("store: update enterprise reserved: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit enterprise release: %w", err)
	}
	return nil
}

func (s *PostgresStore) ListDueEnterpriseAccounts(now time.Time) ([]EnterpriseAccount, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx, `SELECT `+enterpriseAccountColumns+`
		FROM enterprise_accounts
		WHERE status = 'active' AND next_invoice_at <= $1
		ORDER BY next_invoice_at ASC`, now)
	if err != nil {
		return nil, fmt.Errorf("store: list due enterprise accounts: %w", err)
	}
	defer rows.Close()

	var out []EnterpriseAccount
	for rows.Next() {
		a, err := scanEnterpriseAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan due enterprise account: %w", err)
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

const enterpriseInvoiceColumns = `id, account_id, stripe_invoice_id, stripe_hosted_invoice_url,
	stripe_invoice_pdf, status, period_start, period_end, amount_micro_usd,
	amount_cents, terms_days, due_at, sent_at, paid_at, created_at, updated_at`

func scanEnterpriseInvoice(row interface{ Scan(...any) error }) (*EnterpriseInvoice, error) {
	var inv EnterpriseInvoice
	if err := row.Scan(&inv.ID, &inv.AccountID, &inv.StripeInvoiceID, &inv.StripeHostedInvoiceURL,
		&inv.StripeInvoicePDF, &inv.Status, &inv.PeriodStart, &inv.PeriodEnd,
		&inv.AmountMicroUSD, &inv.AmountCents, &inv.TermsDays, &inv.DueAt,
		&inv.SentAt, &inv.PaidAt, &inv.CreatedAt, &inv.UpdatedAt); err != nil {
		return nil, err
	}
	return &inv, nil
}

func (s *PostgresStore) CreateEnterpriseInvoice(invoice *EnterpriseInvoice) error {
	if invoice == nil || invoice.ID == "" || invoice.AccountID == "" {
		return errors.New("enterprise invoice id and account_id are required")
	}
	if invoice.AmountMicroUSD < 0 || invoice.AmountCents < 0 {
		return errors.New("enterprise invoice amount cannot be negative")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin create enterprise invoice: %w", err)
	}
	defer tx.Rollback(ctx)

	var existingStripeID string
	err = tx.QueryRow(ctx, `SELECT stripe_invoice_id FROM enterprise_invoices
		WHERE id = $1 AND account_id = $2 AND amount_micro_usd = $3 AND amount_cents = $4
		FOR UPDATE`, invoice.ID, invoice.AccountID, invoice.AmountMicroUSD, invoice.AmountCents).Scan(&existingStripeID)
	if errors.Is(err, pgx.ErrNoRows) {
		_, err = tx.Exec(ctx, `INSERT INTO enterprise_invoices (
				id, account_id, stripe_invoice_id, stripe_hosted_invoice_url,
				stripe_invoice_pdf, status, period_start, period_end, amount_micro_usd,
				amount_cents, terms_days, due_at, sent_at, paid_at, updated_at
			) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,NOW())`,
			invoice.ID, invoice.AccountID, invoice.StripeInvoiceID, invoice.StripeHostedInvoiceURL,
			invoice.StripeInvoicePDF, invoice.Status, invoice.PeriodStart, invoice.PeriodEnd,
			invoice.AmountMicroUSD, invoice.AmountCents, invoice.TermsDays, invoice.DueAt,
			invoice.SentAt, invoice.PaidAt)
	} else if err == nil && existingStripeID == "" {
		_, err = tx.Exec(ctx, `UPDATE enterprise_invoices SET
				stripe_invoice_id = $2,
				stripe_hosted_invoice_url = $3,
				stripe_invoice_pdf = $4,
				status = $5,
				due_at = $6,
				sent_at = $7,
				paid_at = $8,
				updated_at = NOW()
			WHERE id = $1`,
			invoice.ID, invoice.StripeInvoiceID, invoice.StripeHostedInvoiceURL,
			invoice.StripeInvoicePDF, invoice.Status, invoice.DueAt, invoice.SentAt, invoice.PaidAt)
	} else if err == nil {
		return fmt.Errorf("enterprise invoice %q already exists", invoice.ID)
	}
	if err != nil {
		return fmt.Errorf("store: create enterprise invoice: %w", err)
	}
	_, err = tx.Exec(ctx, `UPDATE enterprise_accounts
		SET open_invoice_micro_usd = open_invoice_micro_usd + $2,
			rounding_carry_micro_usd = GREATEST(accrued_micro_usd + rounding_carry_micro_usd - $2, 0),
			accrued_micro_usd = 0,
			current_period_start = $3,
			next_invoice_at = CASE cadence
				WHEN 'weekly' THEN $3::timestamptz + INTERVAL '7 days'
				WHEN 'biweekly' THEN $3::timestamptz + INTERVAL '14 days'
				ELSE $3::timestamptz + INTERVAL '1 month'
			END,
			updated_at = NOW()
		WHERE account_id = $1`,
		invoice.AccountID, invoice.AmountMicroUSD, invoice.PeriodEnd)
	if err != nil {
		return fmt.Errorf("store: advance enterprise account invoice period: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit create enterprise invoice: %w", err)
	}
	return nil
}

func (s *PostgresStore) CreateEnterpriseInvoiceDraft(invoice *EnterpriseInvoice) error {
	if invoice == nil || invoice.ID == "" || invoice.AccountID == "" {
		return errors.New("enterprise invoice id and account_id are required")
	}
	if invoice.AmountMicroUSD < 0 || invoice.AmountCents < 0 {
		return errors.New("enterprise invoice amount cannot be negative")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx, `INSERT INTO enterprise_invoices (
			id, account_id, stripe_invoice_id, stripe_hosted_invoice_url,
			stripe_invoice_pdf, status, period_start, period_end, amount_micro_usd,
			amount_cents, terms_days, due_at, sent_at, paid_at, updated_at
		) VALUES ($1,$2,'','','',$3,$4,$5,$6,$7,$8,NULL,NULL,NULL,NOW())
		ON CONFLICT (id) DO NOTHING`,
		invoice.ID, invoice.AccountID, EnterpriseInvoiceStatusDraft, invoice.PeriodStart,
		invoice.PeriodEnd, invoice.AmountMicroUSD, invoice.AmountCents, invoice.TermsDays)
	if err != nil {
		return fmt.Errorf("store: create enterprise invoice draft: %w", err)
	}
	return nil
}

func (s *PostgresStore) UpdateEnterpriseInvoice(invoice *EnterpriseInvoice) error {
	if invoice == nil || invoice.ID == "" {
		return errors.New("enterprise invoice id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin update enterprise invoice: %w", err)
	}
	defer tx.Rollback(ctx)

	var oldStatus, accountID string
	var amountMicroUSD int64
	if err := tx.QueryRow(ctx, `SELECT status, account_id, amount_micro_usd FROM enterprise_invoices WHERE id = $1 FOR UPDATE`, invoice.ID).Scan(&oldStatus, &accountID, &amountMicroUSD); err != nil {
		return fmt.Errorf("store: enterprise invoice not found: %w", err)
	}
	newStatus := invoice.Status
	if isEnterpriseInvoiceTerminal(oldStatus) && !isEnterpriseInvoiceTerminal(newStatus) {
		newStatus = oldStatus
	}
	_, err = tx.Exec(ctx, `UPDATE enterprise_invoices SET
			stripe_invoice_id = $2,
			stripe_hosted_invoice_url = $3,
			stripe_invoice_pdf = $4,
			status = $5,
			due_at = $6,
			sent_at = $7,
			paid_at = $8,
			updated_at = NOW()
		WHERE id = $1`,
		invoice.ID, invoice.StripeInvoiceID, invoice.StripeHostedInvoiceURL,
		invoice.StripeInvoicePDF, newStatus, invoice.DueAt, invoice.SentAt, invoice.PaidAt)
	if err != nil {
		return fmt.Errorf("store: update enterprise invoice: %w", err)
	}
	if !isEnterpriseInvoiceTerminal(oldStatus) && isEnterpriseInvoiceTerminal(newStatus) {
		_, err = tx.Exec(ctx, `UPDATE enterprise_accounts
			SET open_invoice_micro_usd = GREATEST(open_invoice_micro_usd - $2, 0), updated_at = NOW()
			WHERE account_id = $1`, accountID, amountMicroUSD)
		if err != nil {
			return fmt.Errorf("store: reduce enterprise open invoices: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit update enterprise invoice: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetEnterpriseInvoiceByStripeID(stripeInvoiceID string) (*EnterpriseInvoice, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx, `SELECT `+enterpriseInvoiceColumns+`
		FROM enterprise_invoices WHERE stripe_invoice_id = $1`, stripeInvoiceID)
	inv, err := scanEnterpriseInvoice(row)
	if err != nil {
		return nil, fmt.Errorf("store: enterprise invoice not found: %w", err)
	}
	return inv, nil
}

func (s *PostgresStore) ListEnterpriseInvoices(accountID string, limit int) ([]EnterpriseInvoice, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	query := `SELECT ` + enterpriseInvoiceColumns + ` FROM enterprise_invoices WHERE account_id = $1 ORDER BY created_at DESC`
	args := []any{accountID}
	if limit > 0 {
		query += ` LIMIT $2`
		args = append(args, limit)
	}
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("store: list enterprise invoices: %w", err)
	}
	defer rows.Close()

	var out []EnterpriseInvoice
	for rows.Next() {
		inv, err := scanEnterpriseInvoice(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan enterprise invoice: %w", err)
		}
		out = append(out, *inv)
	}
	return out, rows.Err()
}

// --- Custom Pricing ---

func (s *PostgresStore) SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO model_prices (account_id, model, input_price, output_price, updated_at)
		 VALUES ($1, $2, $3, $4, NOW())
		 ON CONFLICT (account_id, model) DO UPDATE SET
		   input_price = $3, output_price = $4, updated_at = NOW()`,
		accountID, model, inputPrice, outputPrice,
	)
	if err != nil {
		return fmt.Errorf("store: set model price: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetModelPrice(accountID, model string) (int64, int64, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var input, output int64
	err := s.pool.QueryRow(ctx,
		`SELECT input_price, output_price FROM model_prices WHERE account_id = $1 AND model = $2`,
		accountID, model,
	).Scan(&input, &output)
	if err != nil {
		return 0, 0, false
	}
	return input, output, true
}

func (s *PostgresStore) ListModelPrices(accountID string) []ModelPrice {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT account_id, model, input_price, output_price FROM model_prices WHERE account_id = $1 ORDER BY model`,
		accountID,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var prices []ModelPrice
	for rows.Next() {
		var mp ModelPrice
		if err := rows.Scan(&mp.AccountID, &mp.Model, &mp.InputPrice, &mp.OutputPrice); err != nil {
			continue
		}
		prices = append(prices, mp)
	}
	return prices
}

func (s *PostgresStore) DeleteModelPrice(accountID, model string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`DELETE FROM model_prices WHERE account_id = $1 AND model = $2`,
		accountID, model,
	)
	if err != nil {
		return fmt.Errorf("store: delete model price: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("no custom price for model %q", model)
	}
	return nil
}

// --- Users (Privy) ---

// CreateUser creates a new user record linked to a Privy identity.
func (s *PostgresStore) CreateUser(user *User) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO users (account_id, privy_user_id, email, solana_wallet_address, solana_wallet_id)
		 VALUES ($1, $2, $3, $4, $5)`,
		user.AccountID, user.PrivyUserID, user.Email, user.SolanaWalletAddress, user.SolanaWalletID,
	)
	if err != nil {
		return fmt.Errorf("store: create user: %w", err)
	}
	return nil
}

const userSelectColumns = `account_id, privy_user_id, email, solana_wallet_address, solana_wallet_id,
	stripe_account_id, stripe_account_status, stripe_destination_type,
	stripe_destination_last4, stripe_instant_eligible, created_at`

func scanUser(row interface {
	Scan(...any) error
}) (*User, error) {
	var u User
	if err := row.Scan(&u.AccountID, &u.PrivyUserID, &u.Email, &u.SolanaWalletAddress, &u.SolanaWalletID,
		&u.StripeAccountID, &u.StripeAccountStatus, &u.StripeDestinationType,
		&u.StripeDestinationLast4, &u.StripeInstantEligible, &u.CreatedAt); err != nil {
		return nil, err
	}
	return &u, nil
}

// GetUserByPrivyID returns the user for a Privy DID.
func (s *PostgresStore) GetUserByPrivyID(privyUserID string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+userSelectColumns+` FROM users WHERE privy_user_id = $1`, privyUserID,
	)
	u, err := scanUser(row)
	if err != nil {
		return nil, fmt.Errorf("store: user not found: %w", err)
	}
	return u, nil
}

// GetUserByAccountID returns the user for an internal account ID.
func (s *PostgresStore) GetUserByAccountID(accountID string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+userSelectColumns+` FROM users WHERE account_id = $1`, accountID,
	)
	u, err := scanUser(row)
	if err != nil {
		return nil, fmt.Errorf("store: user not found: %w", err)
	}
	return u, nil
}

// SetUserStripeAccount upserts the Stripe Connect fields on a user record.
func (s *PostgresStore) SetUserStripeAccount(accountID, stripeAccountID, status, destinationType, destinationLast4 string, instantEligible bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE users SET
			stripe_account_id = $2,
			stripe_account_status = $3,
			stripe_destination_type = $4,
			stripe_destination_last4 = $5,
			stripe_instant_eligible = $6
		 WHERE account_id = $1`,
		accountID, stripeAccountID, status, destinationType, destinationLast4, instantEligible,
	)
	if err != nil {
		return fmt.Errorf("store: set stripe account: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	return nil
}

// GetUserByStripeAccount finds a user by their Stripe connected account ID.
func (s *PostgresStore) GetUserByStripeAccount(stripeAccountID string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+userSelectColumns+` FROM users WHERE stripe_account_id = $1`, stripeAccountID,
	)
	u, err := scanUser(row)
	if err != nil {
		return nil, fmt.Errorf("store: user with Stripe account %q not found: %w", stripeAccountID, err)
	}
	return u, nil
}

// GetUserByEmail returns the user for an email address.
func (s *PostgresStore) GetUserByEmail(email string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+userSelectColumns+` FROM users WHERE LOWER(email) = LOWER($1)`, email,
	)
	u, err := scanUser(row)
	if err != nil {
		return nil, fmt.Errorf("user with email %q not found", email)
	}
	return u, nil
}

// --- Stripe Withdrawals ---

func (s *PostgresStore) CreateStripeWithdrawal(w *StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	now := time.Now()
	if w.CreatedAt.IsZero() {
		w.CreatedAt = now
	}
	if w.UpdatedAt.IsZero() {
		w.UpdatedAt = w.CreatedAt
	}

	_, err := s.pool.Exec(ctx,
		`INSERT INTO stripe_withdrawals
		 (id, account_id, stripe_account_id, transfer_id, payout_id,
		  amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
		  failure_reason, refunded, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
		w.ID, w.AccountID, w.StripeAccountID, w.TransferID, w.PayoutID,
		w.AmountMicroUSD, w.FeeMicroUSD, w.NetMicroUSD, w.Method, w.Status,
		w.FailureReason, w.Refunded, w.CreatedAt, w.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("store: create stripe withdrawal: %w", err)
	}
	return nil
}

const stripeWithdrawalSelectColumns = `id, account_id, stripe_account_id, transfer_id, payout_id,
	amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
	failure_reason, refunded, created_at, updated_at`

func scanStripeWithdrawal(row interface{ Scan(...any) error }) (*StripeWithdrawal, error) {
	var w StripeWithdrawal
	if err := row.Scan(&w.ID, &w.AccountID, &w.StripeAccountID, &w.TransferID, &w.PayoutID,
		&w.AmountMicroUSD, &w.FeeMicroUSD, &w.NetMicroUSD, &w.Method, &w.Status,
		&w.FailureReason, &w.Refunded, &w.CreatedAt, &w.UpdatedAt); err != nil {
		return nil, err
	}
	return &w, nil
}

func (s *PostgresStore) GetStripeWithdrawal(id string) (*StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE id = $1`, id)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		return nil, fmt.Errorf("store: stripe withdrawal %q not found: %w", id, err)
	}
	return w, nil
}

func (s *PostgresStore) GetStripeWithdrawalByPayoutID(payoutID string) (*StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE payout_id = $1`, payoutID)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		return nil, fmt.Errorf("store: stripe withdrawal with payout %q not found: %w", payoutID, err)
	}
	return w, nil
}

func (s *PostgresStore) GetStripeWithdrawalByTransferID(transferID string) (*StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE transfer_id = $1`, transferID)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		return nil, fmt.Errorf("store: stripe withdrawal with transfer %q not found: %w", transferID, err)
	}
	return w, nil
}

func (s *PostgresStore) UpdateStripeWithdrawal(w *StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx,
		`UPDATE stripe_withdrawals SET
			transfer_id = $2, payout_id = $3, status = $4,
			failure_reason = $5, refunded = $6, updated_at = NOW()
		 WHERE id = $1`,
		w.ID, w.TransferID, w.PayoutID, w.Status, w.FailureReason, w.Refunded,
	)
	if err != nil {
		return fmt.Errorf("store: update stripe withdrawal: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("stripe withdrawal %q not found", w.ID)
	}
	w.UpdatedAt = time.Now()
	return nil
}

func (s *PostgresStore) ListStripeWithdrawals(accountID string, limit int) ([]StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	q := `SELECT ` + stripeWithdrawalSelectColumns + ` FROM stripe_withdrawals WHERE account_id = $1 ORDER BY created_at DESC`
	args := []any{accountID}
	if limit > 0 {
		q += ` LIMIT $2`
		args = append(args, limit)
	}
	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals: %w", err)
	}
	defer rows.Close()

	var out []StripeWithdrawal
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	if out == nil {
		return []StripeWithdrawal{}, nil
	}
	return out, nil
}

// --- Supported Models ---

func (s *PostgresStore) SetSupportedModel(model *SupportedModel) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO supported_models (id, s3_name, display_name, model_type, size_gb, architecture, description, min_ram_gb, active, weight_hash, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
		 ON CONFLICT (id) DO UPDATE SET
		   s3_name = $2, display_name = $3, model_type = $4, size_gb = $5, architecture = $6,
		   description = $7, min_ram_gb = $8, active = $9, weight_hash = $10, updated_at = NOW()`,
		model.ID, model.S3Name, model.DisplayName, model.ModelType, model.SizeGB,
		model.Architecture, model.Description, model.MinRAMGB, model.Active, model.WeightHash,
	)
	if err != nil {
		return fmt.Errorf("store: set supported model: %w", err)
	}
	return nil
}

func (s *PostgresStore) ListSupportedModels() []SupportedModel {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, s3_name, display_name, model_type, size_gb, architecture, description, min_ram_gb, active, weight_hash
		 FROM supported_models ORDER BY model_type ASC, min_ram_gb ASC, size_gb ASC`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var models []SupportedModel
	for rows.Next() {
		var m SupportedModel
		if err := rows.Scan(&m.ID, &m.S3Name, &m.DisplayName, &m.ModelType, &m.SizeGB,
			&m.Architecture, &m.Description, &m.MinRAMGB, &m.Active, &m.WeightHash); err != nil {
			continue
		}
		models = append(models, m)
	}
	return models
}

func (s *PostgresStore) DeleteSupportedModel(modelID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`DELETE FROM supported_models WHERE id = $1`, modelID,
	)
	if err != nil {
		return fmt.Errorf("store: delete supported model: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("model %q not found", modelID)
	}
	return nil
}

// --- Releases ---

func (s *PostgresStore) SetRelease(release *Release) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO releases (version, platform, binary_hash, bundle_hash, python_hash, runtime_hash, template_hashes, url, changelog, active, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, TRUE, NOW())
		 ON CONFLICT (version, platform) DO UPDATE SET
		   binary_hash = $3, bundle_hash = $4, python_hash = $5, runtime_hash = $6, template_hashes = $7, url = $8, changelog = $9, active = TRUE`,
		release.Version, release.Platform, release.BinaryHash, release.BundleHash,
		release.PythonHash, release.RuntimeHash, release.TemplateHashes,
		release.URL, release.Changelog,
	)
	if err != nil {
		return fmt.Errorf("store: set release: %w", err)
	}
	return nil
}

func (s *PostgresStore) ListReleases() []Release {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT version, platform, binary_hash, bundle_hash,
		        COALESCE(python_hash, ''), COALESCE(runtime_hash, ''), COALESCE(template_hashes, ''),
		        url, changelog, active, created_at
		 FROM releases ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var releases []Release
	for rows.Next() {
		var r Release
		if err := rows.Scan(&r.Version, &r.Platform, &r.BinaryHash, &r.BundleHash,
			&r.PythonHash, &r.RuntimeHash, &r.TemplateHashes,
			&r.URL, &r.Changelog, &r.Active, &r.CreatedAt); err != nil {
			continue
		}
		releases = append(releases, r)
	}
	return releases
}

func (s *PostgresStore) GetLatestRelease(platform string) *Release {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT version, platform, binary_hash, bundle_hash,
		        COALESCE(python_hash, ''), COALESCE(runtime_hash, ''), COALESCE(template_hashes, ''),
		        url, changelog, active, created_at
		 FROM releases WHERE platform = $1 AND active = TRUE`, platform,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var latest *Release
	for rows.Next() {
		var r Release
		if err := rows.Scan(&r.Version, &r.Platform, &r.BinaryHash, &r.BundleHash,
			&r.PythonHash, &r.RuntimeHash, &r.TemplateHashes,
			&r.URL, &r.Changelog, &r.Active, &r.CreatedAt); err != nil {
			return nil
		}
		if latest == nil ||
			releaseVersionGreater(r.Version, latest.Version) ||
			(r.Version == latest.Version && r.CreatedAt.After(latest.CreatedAt)) {
			copy := r
			latest = &copy
		}
	}
	if rows.Err() != nil || latest == nil {
		return nil
	}
	return latest
}

func (s *PostgresStore) DeleteRelease(version, platform string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE releases SET active = FALSE WHERE version = $1 AND platform = $2`,
		version, platform,
	)
	if err != nil {
		return fmt.Errorf("store: delete release: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("release %s/%s not found", version, platform)
	}
	return nil
}

// --- Device Authorization ---

func (s *PostgresStore) CreateDeviceCode(dc *DeviceCode) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO device_codes (device_code, user_code, account_id, status, expires_at)
		 VALUES ($1, $2, $3, $4, $5)`,
		dc.DeviceCode, dc.UserCode, dc.AccountID, dc.Status, dc.ExpiresAt,
	)
	if err != nil {
		return fmt.Errorf("store: create device code: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetDeviceCode(deviceCode string) (*DeviceCode, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var dc DeviceCode
	err := s.pool.QueryRow(ctx,
		`SELECT device_code, user_code, account_id, status, expires_at, created_at
		 FROM device_codes WHERE device_code = $1`, deviceCode,
	).Scan(&dc.DeviceCode, &dc.UserCode, &dc.AccountID, &dc.Status, &dc.ExpiresAt, &dc.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: device code not found: %w", err)
	}
	return &dc, nil
}

func (s *PostgresStore) GetDeviceCodeByUserCode(userCode string) (*DeviceCode, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var dc DeviceCode
	err := s.pool.QueryRow(ctx,
		`SELECT device_code, user_code, account_id, status, expires_at, created_at
		 FROM device_codes WHERE user_code = $1`, userCode,
	).Scan(&dc.DeviceCode, &dc.UserCode, &dc.AccountID, &dc.Status, &dc.ExpiresAt, &dc.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: user code not found: %w", err)
	}
	return &dc, nil
}

func (s *PostgresStore) ApproveDeviceCode(deviceCode, accountID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE device_codes SET status = 'approved', account_id = $2
		 WHERE device_code = $1 AND status = 'pending' AND expires_at > NOW()`,
		deviceCode, accountID,
	)
	if err != nil {
		return fmt.Errorf("store: approve device code: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return errors.New("device code not found, not pending, or expired")
	}
	return nil
}

func (s *PostgresStore) DeleteExpiredDeviceCodes() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx, `DELETE FROM device_codes WHERE expires_at < NOW()`)
	if err != nil {
		return fmt.Errorf("store: delete expired device codes: %w", err)
	}
	return nil
}

// --- Provider Tokens ---

func (s *PostgresStore) CreateProviderToken(pt *ProviderToken) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_tokens (token_hash, account_id, label, active)
		 VALUES ($1, $2, $3, $4)`,
		pt.TokenHash, pt.AccountID, pt.Label, pt.Active,
	)
	if err != nil {
		return fmt.Errorf("store: create provider token: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetProviderToken(token string) (*ProviderToken, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	h := hashKey(token)
	var pt ProviderToken
	err := s.pool.QueryRow(ctx,
		`SELECT token_hash, account_id, label, active, created_at
		 FROM provider_tokens WHERE token_hash = $1 AND active = TRUE`, h,
	).Scan(&pt.TokenHash, &pt.AccountID, &pt.Label, &pt.Active, &pt.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: provider token not found: %w", err)
	}
	return &pt, nil
}

func (s *PostgresStore) RevokeProviderToken(token string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	h := hashKey(token)
	tag, err := s.pool.Exec(ctx,
		`UPDATE provider_tokens SET active = FALSE WHERE token_hash = $1`, h,
	)
	if err != nil {
		return fmt.Errorf("store: revoke provider token: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return errors.New("provider token not found")
	}
	return nil
}

// --- Invite Codes ---

func (s *PostgresStore) CreateInviteCode(code *InviteCode) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO invite_codes (code, amount_micro_usd, max_uses, used_count, active, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6)`,
		code.Code, code.AmountMicroUSD, code.MaxUses, code.UsedCount, code.Active, code.ExpiresAt,
	)
	if err != nil {
		return fmt.Errorf("store: create invite code: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetInviteCode(code string) (*InviteCode, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var ic InviteCode
	err := s.pool.QueryRow(ctx,
		`SELECT code, amount_micro_usd, max_uses, used_count, active, expires_at, created_at
		 FROM invite_codes WHERE code = $1`, code,
	).Scan(&ic.Code, &ic.AmountMicroUSD, &ic.MaxUses, &ic.UsedCount, &ic.Active, &ic.ExpiresAt, &ic.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: invite code not found: %w", err)
	}
	return &ic, nil
}

func (s *PostgresStore) ListInviteCodes() []InviteCode {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT code, amount_micro_usd, max_uses, used_count, active, expires_at, created_at
		 FROM invite_codes ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var codes []InviteCode
	for rows.Next() {
		var ic InviteCode
		if err := rows.Scan(&ic.Code, &ic.AmountMicroUSD, &ic.MaxUses, &ic.UsedCount, &ic.Active, &ic.ExpiresAt, &ic.CreatedAt); err != nil {
			continue
		}
		codes = append(codes, ic)
	}
	return codes
}

func (s *PostgresStore) DeactivateInviteCode(code string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE invite_codes SET active = FALSE WHERE code = $1`, code,
	)
	if err != nil {
		return fmt.Errorf("store: deactivate invite code: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("invite code %q not found", code)
	}
	return nil
}

func (s *PostgresStore) RedeemInviteCode(code string, accountID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Lock the invite code row
	var ic InviteCode
	err = tx.QueryRow(ctx,
		`SELECT code, amount_micro_usd, max_uses, used_count, active, expires_at
		 FROM invite_codes WHERE code = $1 FOR UPDATE`, code,
	).Scan(&ic.Code, &ic.AmountMicroUSD, &ic.MaxUses, &ic.UsedCount, &ic.Active, &ic.ExpiresAt)
	if err != nil {
		return fmt.Errorf("invite code %q not found", code)
	}
	if !ic.Active {
		return fmt.Errorf("invite code %q is inactive", code)
	}
	if ic.ExpiresAt != nil && time.Now().After(*ic.ExpiresAt) {
		return fmt.Errorf("invite code %q has expired", code)
	}
	if ic.MaxUses > 0 && ic.UsedCount >= ic.MaxUses {
		return fmt.Errorf("invite code %q has reached max uses", code)
	}

	// Insert redemption (PK constraint prevents double-redemption)
	_, err = tx.Exec(ctx,
		`INSERT INTO invite_redemptions (code, account_id) VALUES ($1, $2)`,
		code, accountID,
	)
	if err != nil {
		return fmt.Errorf("account has already redeemed code %q", code)
	}

	// Increment used_count
	_, err = tx.Exec(ctx,
		`UPDATE invite_codes SET used_count = used_count + 1 WHERE code = $1`, code,
	)
	if err != nil {
		return fmt.Errorf("store: update invite code: %w", err)
	}

	return tx.Commit(ctx)
}

func (s *PostgresStore) HasRedeemedInviteCode(code, accountID string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var count int
	_ = s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM invite_redemptions WHERE code = $1 AND account_id = $2`,
		code, accountID,
	).Scan(&count)
	return count > 0
}

// --- Provider Earnings ---

// RecordProviderEarning stores an earning record for a specific provider node.
func (s *PostgresStore) RecordProviderEarning(earning *ProviderEarning) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		earning.AccountID, earning.ProviderID, earning.ProviderKey, earning.JobID,
		earning.Model, earning.AmountMicroUSD, earning.PromptTokens, earning.CompletionTokens,
	)
	if err != nil {
		return fmt.Errorf("store: insert provider earning: %w", err)
	}
	return nil
}

// GetProviderEarnings returns earnings for a specific provider node (by public key), newest first.
func (s *PostgresStore) GetProviderEarnings(providerKey string, limit int) ([]ProviderEarning, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
		 FROM provider_earnings
		 WHERE provider_key = $1
		 ORDER BY created_at DESC
		 LIMIT $2`,
		providerKey, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("store: query provider earnings: %w", err)
	}
	defer rows.Close()

	var results []ProviderEarning
	for rows.Next() {
		var e ProviderEarning
		if err := rows.Scan(&e.ID, &e.AccountID, &e.ProviderID, &e.ProviderKey, &e.JobID,
			&e.Model, &e.AmountMicroUSD, &e.PromptTokens, &e.CompletionTokens, &e.CreatedAt); err != nil {
			continue
		}
		results = append(results, e)
	}
	if results == nil {
		return []ProviderEarning{}, nil
	}
	return results, nil
}

// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
func (s *PostgresStore) GetAccountEarnings(accountID string, limit int) ([]ProviderEarning, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
		 FROM provider_earnings
		 WHERE account_id = $1
		 ORDER BY created_at DESC
		 LIMIT $2`,
		accountID, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("store: query account earnings: %w", err)
	}
	defer rows.Close()

	var results []ProviderEarning
	for rows.Next() {
		var e ProviderEarning
		if err := rows.Scan(&e.ID, &e.AccountID, &e.ProviderID, &e.ProviderKey, &e.JobID,
			&e.Model, &e.AmountMicroUSD, &e.PromptTokens, &e.CompletionTokens, &e.CreatedAt); err != nil {
			continue
		}
		results = append(results, e)
	}
	if results == nil {
		return []ProviderEarning{}, nil
	}
	return results, nil
}

// GetProviderEarningsSummary returns lifetime aggregates for a provider node.
func (s *PostgresStore) GetProviderEarningsSummary(providerKey string) (ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary ProviderEarningsSummary
	if err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*),
		        COALESCE(SUM(amount_micro_usd), 0),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM provider_earnings
		 WHERE provider_key = $1`,
		providerKey,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens); err != nil {
		return ProviderEarningsSummary{}, fmt.Errorf("store: query provider earnings summary: %w", err)
	}

	return summary, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
func (s *PostgresStore) GetAccountEarningsSummary(accountID string) (ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary ProviderEarningsSummary
	if err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*),
		        COALESCE(SUM(amount_micro_usd), 0),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM provider_earnings
		 WHERE account_id = $1`,
		accountID,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens); err != nil {
		return ProviderEarningsSummary{}, fmt.Errorf("store: query account earnings summary: %w", err)
	}

	return summary, nil
}

// RecordProviderPayout stores a payout record for a provider wallet.
func (s *PostgresStore) RecordProviderPayout(payout *ProviderPayout) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_payouts (provider_address, amount_micro_usd, model, job_id, settled, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		payout.ProviderAddress, payout.AmountMicroUSD, payout.Model, payout.JobID, payout.Settled, nullableCreatedAt(payout.Timestamp),
	)
	if err != nil {
		return fmt.Errorf("store: insert provider payout: %w", err)
	}

	return nil
}

// ListProviderPayouts returns all provider payout records in creation order.
func (s *PostgresStore) ListProviderPayouts() ([]ProviderPayout, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, provider_address, amount_micro_usd, model, job_id, settled, created_at
		 FROM provider_payouts
		 ORDER BY id ASC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: query provider payouts: %w", err)
	}
	defer rows.Close()

	var results []ProviderPayout
	for rows.Next() {
		var payout ProviderPayout
		if err := rows.Scan(&payout.ID, &payout.ProviderAddress, &payout.AmountMicroUSD, &payout.Model, &payout.JobID, &payout.Settled, &payout.Timestamp); err != nil {
			continue
		}
		results = append(results, payout)
	}
	if results == nil {
		return []ProviderPayout{}, nil
	}

	return results, nil
}

// SettleProviderPayout marks a provider payout as settled.
func (s *PostgresStore) SettleProviderPayout(id int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE provider_payouts
		 SET settled = TRUE
		 WHERE id = $1 AND settled = FALSE`,
		id,
	)
	if err != nil {
		return fmt.Errorf("store: settle provider payout: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("provider payout %d not found or already settled", id)
	}

	return nil
}

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning.
func (s *PostgresStore) CreditProviderAccount(earning *ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := creditWithdrawableTx(ctx, tx, earning.AccountID, earning.AmountMicroUSD, LedgerPayout, earning.JobID, earning.CreatedAt); err != nil {
		return err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO provider_earnings (
			account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, COALESCE($9, NOW()))`,
		earning.AccountID,
		earning.ProviderID,
		earning.ProviderKey,
		earning.JobID,
		earning.Model,
		earning.AmountMicroUSD,
		earning.PromptTokens,
		earning.CompletionTokens,
		nullableCreatedAt(earning.CreatedAt),
	)
	if err != nil {
		return fmt.Errorf("store: insert provider earning: %w", err)
	}

	return tx.Commit(ctx)
}

// CreditProviderWallet atomically credits an unlinked provider wallet and
// records the corresponding payout history row.
func (s *PostgresStore) CreditProviderWallet(payout *ProviderPayout) error {
	if payout == nil {
		return errors.New("provider payout is required")
	}
	if payout.ProviderAddress == "" {
		return errors.New("provider payout address is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := creditWithdrawableTx(ctx, tx, payout.ProviderAddress, payout.AmountMicroUSD, LedgerPayout, payout.JobID, payout.Timestamp); err != nil {
		return err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO provider_payouts (provider_address, amount_micro_usd, model, job_id, settled, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		payout.ProviderAddress,
		payout.AmountMicroUSD,
		payout.Model,
		payout.JobID,
		payout.Settled,
		nullableCreatedAt(payout.Timestamp),
	)
	if err != nil {
		return fmt.Errorf("store: insert provider payout: %w", err)
	}

	return tx.Commit(ctx)
}

// --- Provider Fleet Persistence ---

func (s *PostgresStore) UpsertProvider(ctx context.Context, p ProviderRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO providers (
			id, hardware, models, backend, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen
		) VALUES (
			$1, $2, $3, $4, $5, $6,
			$7, $8, $9,
			$10, $11, $12,
			$13, $14, $15, $16,
			$17, $18, $19,
			$20, $21, $22, $23,
			$24, $25
		)
		ON CONFLICT (id) DO UPDATE SET
			hardware = $2, models = $3, backend = $4,
			trust_level = $5, attested = $6,
			attestation_result = $7, se_public_key = $8, serial_number = $9,
			mda_verified = $10, mda_cert_chain = $11, acme_verified = $12,
			version = $13, runtime_verified = $14, python_hash = $15, runtime_hash = $16,
			last_challenge_verified = $17, failed_challenges = $18, account_id = $19,
			lifetime_requests_served = $20, lifetime_tokens_generated = $21,
			last_session_requests_served = $22, last_session_tokens_generated = $23,
			last_seen = $25`,
		p.ID, p.Hardware, p.Models, p.Backend,
		p.TrustLevel, p.Attested,
		p.AttestationResult, p.SEPublicKey, p.SerialNumber,
		p.MDAVerified, p.MDACertChain, p.ACMEVerified,
		p.Version, p.RuntimeVerified, p.PythonHash, p.RuntimeHash,
		p.LastChallengeVerified, p.FailedChallenges, p.AccountID,
		p.LifetimeRequestsServed, p.LifetimeTokensGenerated,
		p.LastSessionRequestsServed, p.LastSessionTokensGenerated,
		p.RegisteredAt, p.LastSeen,
	)
	if err != nil {
		return fmt.Errorf("store: upsert provider: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetProviderRecord(ctx context.Context, id string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var p ProviderRecord
	err := s.pool.QueryRow(ctx,
		`SELECT id, hardware, models, backend, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen
		 FROM providers WHERE id = $1`, id,
	).Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
		&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
		&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
		&p.RegisteredAt, &p.LastSeen,
	)
	if err != nil {
		return nil, fmt.Errorf("store: provider not found: %w", err)
	}
	return &p, nil
}

func (s *PostgresStore) GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var p ProviderRecord
	err := s.pool.QueryRow(ctx,
		`SELECT id, hardware, models, backend, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen
		 FROM providers WHERE serial_number = $1 AND serial_number != ''
		 ORDER BY last_seen DESC LIMIT 1`, serial,
	).Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
		&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
		&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
		&p.RegisteredAt, &p.LastSeen,
	)
	if err != nil {
		return nil, fmt.Errorf("store: provider with serial not found: %w", err)
	}
	return &p, nil
}

func (s *PostgresStore) ListProviderRecords(ctx context.Context) ([]ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, hardware, models, backend, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen
		 FROM providers ORDER BY last_seen DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list providers: %w", err)
	}
	defer rows.Close()

	var records []ProviderRecord
	for rows.Next() {
		var p ProviderRecord
		if err := rows.Scan(
			&p.ID, &p.Hardware, &p.Models, &p.Backend,
			&p.TrustLevel, &p.Attested,
			&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
			&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
			&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
			&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
			&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
			&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
			&p.RegisteredAt, &p.LastSeen,
		); err != nil {
			continue
		}
		records = append(records, p)
	}
	if records == nil {
		return []ProviderRecord{}, nil
	}
	return records, nil
}

func (s *PostgresStore) ListProvidersByAccount(ctx context.Context, accountID string) ([]ProviderRecord, error) {
	if accountID == "" {
		return []ProviderRecord{}, nil
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	// Dedupe in SQL: many session UUIDs can map to the same physical
	// machine (one row per reconnect). Pick the most-recent row per
	// stable identity (serial → SE key → id) so we don't return tens
	// of thousands of historical rows for accounts with churny providers.
	rows, err := s.pool.Query(ctx,
		`SELECT DISTINCT ON (
			COALESCE(NULLIF(serial_number, ''),
			         NULLIF(se_public_key, ''),
			         id)
		 )
		 id, hardware, models, backend, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen
		 FROM providers
		 WHERE account_id = $1
		 ORDER BY COALESCE(NULLIF(serial_number, ''),
		                   NULLIF(se_public_key, ''),
		                   id),
		          last_seen DESC`,
		accountID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list providers by account: %w", err)
	}
	defer rows.Close()

	records := make([]ProviderRecord, 0)
	for rows.Next() {
		var p ProviderRecord
		if err := rows.Scan(
			&p.ID, &p.Hardware, &p.Models, &p.Backend,
			&p.TrustLevel, &p.Attested,
			&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
			&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
			&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
			&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
			&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
			&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
			&p.RegisteredAt, &p.LastSeen,
		); err != nil {
			continue
		}
		records = append(records, p)
	}
	return records, nil
}

func (s *PostgresStore) UpdateProviderLastSeen(ctx context.Context, id string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE providers SET last_seen = NOW() WHERE id = $1`, id,
	)
	if err != nil {
		return fmt.Errorf("store: update provider last_seen: %w", err)
	}
	return nil
}

func (s *PostgresStore) UpdateProviderTrust(ctx context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE providers SET trust_level = $2, attested = $3, attestation_result = $4
		 WHERE id = $1`,
		id, trustLevel, attested, attestationResult,
	)
	if err != nil {
		return fmt.Errorf("store: update provider trust: %w", err)
	}
	return nil
}

func (s *PostgresStore) UpdateProviderChallenge(ctx context.Context, id string, lastVerified time.Time, failedCount int) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE providers SET last_challenge_verified = $2, failed_challenges = $3
		 WHERE id = $1`,
		id, lastVerified, failedCount,
	)
	if err != nil {
		return fmt.Errorf("store: update provider challenge: %w", err)
	}
	return nil
}

func (s *PostgresStore) UpdateProviderRuntime(ctx context.Context, id string, verified bool, pythonHash, runtimeHash string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE providers SET runtime_verified = $2, python_hash = $3, runtime_hash = $4
		 WHERE id = $1`,
		id, verified, pythonHash, runtimeHash,
	)
	if err != nil {
		return fmt.Errorf("store: update provider runtime: %w", err)
	}
	return nil
}

// --- Provider Reputation Persistence ---

func (s *PostgresStore) UpsertReputation(ctx context.Context, providerID string, rep ReputationRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_reputation (
			provider_id, total_jobs, successful_jobs, failed_jobs,
			total_uptime_seconds, avg_response_time_ms,
			challenges_passed, challenges_failed, updated_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
		ON CONFLICT (provider_id) DO UPDATE SET
			total_jobs = $2, successful_jobs = $3, failed_jobs = $4,
			total_uptime_seconds = $5, avg_response_time_ms = $6,
			challenges_passed = $7, challenges_failed = $8,
			updated_at = NOW()`,
		providerID, rep.TotalJobs, rep.SuccessfulJobs, rep.FailedJobs,
		rep.TotalUptimeSeconds, rep.AvgResponseTimeMs,
		rep.ChallengesPassed, rep.ChallengesFailed,
	)
	if err != nil {
		return fmt.Errorf("store: upsert reputation: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetReputation(ctx context.Context, providerID string) (*ReputationRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var rep ReputationRecord
	err := s.pool.QueryRow(ctx,
		`SELECT total_jobs, successful_jobs, failed_jobs,
			total_uptime_seconds, avg_response_time_ms,
			challenges_passed, challenges_failed
		 FROM provider_reputation WHERE provider_id = $1`, providerID,
	).Scan(
		&rep.TotalJobs, &rep.SuccessfulJobs, &rep.FailedJobs,
		&rep.TotalUptimeSeconds, &rep.AvgResponseTimeMs,
		&rep.ChallengesPassed, &rep.ChallengesFailed,
	)
	if err != nil {
		return nil, fmt.Errorf("store: reputation not found: %w", err)
	}
	return &rep, nil
}
