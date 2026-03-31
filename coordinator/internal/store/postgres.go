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
			last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS api_keys (
			key_hash TEXT PRIMARY KEY,
			raw_prefix TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			active BOOLEAN NOT NULL DEFAULT TRUE
		)`,
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

		// Users — Privy identity → internal account mapping
		`CREATE TABLE IF NOT EXISTS users (
			account_id TEXT PRIMARY KEY,
			privy_user_id TEXT UNIQUE NOT NULL,
			solana_wallet_address TEXT NOT NULL DEFAULT '',
			solana_wallet_id TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy ON users(privy_user_id)`,
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
	raw := "dginf-" + hex.EncodeToString(b)
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

// --- Users (Privy) ---

// CreateUser creates a new user record linked to a Privy identity.
func (s *PostgresStore) CreateUser(user *User) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO users (account_id, privy_user_id, solana_wallet_address, solana_wallet_id)
		 VALUES ($1, $2, $3, $4)`,
		user.AccountID, user.PrivyUserID, user.SolanaWalletAddress, user.SolanaWalletID,
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
		`SELECT account_id, privy_user_id, solana_wallet_address, solana_wallet_id, created_at
		 FROM users WHERE privy_user_id = $1`, privyUserID,
	).Scan(&u.AccountID, &u.PrivyUserID, &u.SolanaWalletAddress, &u.SolanaWalletID, &u.CreatedAt)
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
		`SELECT account_id, privy_user_id, solana_wallet_address, solana_wallet_id, created_at
		 FROM users WHERE account_id = $1`, accountID,
	).Scan(&u.AccountID, &u.PrivyUserID, &u.SolanaWalletAddress, &u.SolanaWalletID, &u.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: user not found: %w", err)
	}
	return &u, nil
}
