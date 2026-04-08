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
	"fmt"
	"time"

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
	pool, err := pgxpool.New(ctx, connString)
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
			account_id TEXT NOT NULL DEFAULT ''
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
		`CREATE INDEX IF NOT EXISTS idx_providers_serial ON providers(serial_number) WHERE serial_number != ''`,

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
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
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

// Credit adds micro-USD to an account and records a ledger entry (atomic).
func (s *PostgresStore) Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Upsert balance
	_, err = tx.Exec(ctx,
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

	// Get balance after update
	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balanceAfter)
	if err != nil {
		return fmt.Errorf("store: read balance: %w", err)
	}

	// Record ledger entry
	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, $5)`,
		accountID, string(entryType), amountMicroUSD, balanceAfter, reference,
	)
	if err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
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
		return fmt.Errorf("insufficient balance or account not found")
	}

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

// LedgerHistory returns ledger entries for an account, newest first.
func (s *PostgresStore) LedgerHistory(accountID string) []LedgerEntry {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, account_id, entry_type, amount_micro_usd, balance_after, reference, created_at
		 FROM ledger_entries WHERE account_id = $1 ORDER BY created_at DESC`,
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

// GetUserByPrivyID returns the user for a Privy DID.
func (s *PostgresStore) GetUserByPrivyID(privyUserID string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var u User
	err := s.pool.QueryRow(ctx,
		`SELECT account_id, privy_user_id, email, solana_wallet_address, solana_wallet_id, created_at
		 FROM users WHERE privy_user_id = $1`, privyUserID,
	).Scan(&u.AccountID, &u.PrivyUserID, &u.Email, &u.SolanaWalletAddress, &u.SolanaWalletID, &u.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: user not found: %w", err)
	}
	return &u, nil
}

// GetUserByAccountID returns the user for an internal account ID.
func (s *PostgresStore) GetUserByAccountID(accountID string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var u User
	err := s.pool.QueryRow(ctx,
		`SELECT account_id, privy_user_id, email, solana_wallet_address, solana_wallet_id, created_at
		 FROM users WHERE account_id = $1`, accountID,
	).Scan(&u.AccountID, &u.PrivyUserID, &u.Email, &u.SolanaWalletAddress, &u.SolanaWalletID, &u.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: user not found: %w", err)
	}
	return &u, nil
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

	var r Release
	err := s.pool.QueryRow(ctx,
		`SELECT version, platform, binary_hash, bundle_hash,
		        COALESCE(python_hash, ''), COALESCE(runtime_hash, ''), COALESCE(template_hashes, ''),
		        url, changelog, active, created_at
		 FROM releases WHERE platform = $1 AND active = TRUE
		 ORDER BY created_at DESC LIMIT 1`, platform,
	).Scan(&r.Version, &r.Platform, &r.BinaryHash, &r.BundleHash,
		&r.PythonHash, &r.RuntimeHash, &r.TemplateHashes,
		&r.URL, &r.Changelog, &r.Active, &r.CreatedAt)
	if err != nil {
		return nil
	}
	return &r
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
		return fmt.Errorf("device code not found, not pending, or expired")
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
		return fmt.Errorf("provider token not found")
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
			registered_at, last_seen
		) VALUES (
			$1, $2, $3, $4, $5, $6,
			$7, $8, $9,
			$10, $11, $12,
			$13, $14, $15, $16,
			$17, $18, $19,
			$20, $21
		)
		ON CONFLICT (id) DO UPDATE SET
			hardware = $2, models = $3, backend = $4,
			trust_level = $5, attested = $6,
			attestation_result = $7, se_public_key = $8, serial_number = $9,
			mda_verified = $10, mda_cert_chain = $11, acme_verified = $12,
			version = $13, runtime_verified = $14, python_hash = $15, runtime_hash = $16,
			last_challenge_verified = $17, failed_challenges = $18, account_id = $19,
			last_seen = $21`,
		p.ID, p.Hardware, p.Models, p.Backend,
		p.TrustLevel, p.Attested,
		p.AttestationResult, p.SEPublicKey, p.SerialNumber,
		p.MDAVerified, p.MDACertChain, p.ACMEVerified,
		p.Version, p.RuntimeVerified, p.PythonHash, p.RuntimeHash,
		p.LastChallengeVerified, p.FailedChallenges, p.AccountID,
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
			registered_at, last_seen
		 FROM providers WHERE id = $1`, id,
	).Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
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
