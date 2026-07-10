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
// Schema migrations are applied out of process by coordinator-migrate.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Compile-time check that PostgresStore implements Store.
var _ Store = (*PostgresStore)(nil)

// PostgresStore is a PostgreSQL-backed implementation of Store.
type PostgresStore struct {
	pool *pgxpool.Pool
	// ownershipConn holds the process-wide coordinator advisory lock for the
	// lifetime of this store. Losing/closing the connection releases authority.
	ownershipConn     *pgxpool.Conn
	ownershipEnabled  bool
	ownershipHealthy  atomic.Bool
	ownershipLost     chan struct{}
	ownershipStop     chan struct{}
	ownershipDone     chan struct{}
	ownershipLostOnce sync.Once
	ownershipID       string
	ownershipEpoch    int64

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

// NewPostgres connects to PostgreSQL and verifies that its already-migrated
// schema is compatible with this binary. It never applies DDL or DML.
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
	if err := checkSchemaCompatibility(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

// Close shuts down the connection pool.
func (s *PostgresStore) Close() {
	if s.ownershipConn != nil {
		close(s.ownershipStop)
		<-s.ownershipDone
		_, _ = s.ownershipConn.Exec(
			context.Background(),
			`UPDATE coordinator_ownership SET owner_id = ''
			 WHERE singleton = TRUE AND epoch = $1 AND owner_id = $2`,
			s.ownershipEpoch, s.ownershipID,
		)
		_, _ = s.ownershipConn.Exec(
			context.Background(),
			`SELECT pg_advisory_unlock(hashtextextended('darkbloom-coordinator-owner', 0))`,
		)
		s.ownershipConn.Release()
		s.ownershipConn = nil
	}
	s.pool.Close()
}

func (s *PostgresStore) OwnershipLost() <-chan struct{} {
	if !s.ownershipEnabled {
		return nil
	}
	return s.ownershipLost
}

func (s *PostgresStore) ensureOwnership() error {
	if s.ownershipEnabled && !s.ownershipHealthy.Load() {
		return ErrOwnershipLost
	}
	return nil
}

func (s *PostgresStore) verifyOwnershipTx(ctx context.Context, tx pgx.Tx) error {
	if !s.ownershipEnabled {
		return nil
	}
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	var valid bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM coordinator_ownership
			WHERE singleton = TRUE AND epoch = $1 AND owner_id = $2
			FOR SHARE
		)`,
		s.ownershipEpoch, s.ownershipID,
	).Scan(&valid); err != nil {
		return fmt.Errorf("store: verify coordinator ownership: %w", err)
	}
	if !valid {
		s.ownershipHealthy.Store(false)
		s.ownershipLostOnce.Do(func() { close(s.ownershipLost) })
		return ErrOwnershipLost
	}
	return nil
}

func (s *PostgresStore) monitorOwnership() {
	defer close(s.ownershipDone)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-s.ownershipStop:
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			var one int
			err := s.ownershipConn.QueryRow(ctx, `SELECT 1`).Scan(&one)
			cancel()
			if err != nil || one != 1 {
				s.ownershipHealthy.Store(false)
				s.ownershipLostOnce.Do(func() { close(s.ownershipLost) })
				return
			}
		}
	}
}

// hashKey returns the SHA-256 hex digest of the given API key.
func hashKey(key string) string {
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:])
}

// HashKey returns the SHA-256 hex digest of the given API key.
func HashKey(key string) string { return hashKey(key) }

// apiKeyColumns is the canonical SELECT list for reading an api_keys row into
// an APIKey via scanAPIKeyRow.
const apiKeyColumns = `id, owner_account_id, name, raw_prefix, key_hash, active,
	limit_micro_usd, limit_reset, rpm_limit, itpm_limit, otpm_limit,
	allowed_models, expires_at, created_at, last_used_at, self_route_only`

// rowScanner is satisfied by both pgx.Row and pgx.Rows.
type rowScanner interface {
	Scan(dest ...any) error
}

// scanAPIKeyRow scans one api_keys row (selected via apiKeyColumns) into APIKey.
func scanAPIKeyRow(row rowScanner) (*APIKey, error) {
	var (
		k          APIKey
		active     bool
		limit      *int64
		rpm        *int64
		itpm       *int64
		otpm       *int64
		allowed    string
		expiresAt  *time.Time
		lastUsedAt *time.Time
	)
	if err := row.Scan(&k.ID, &k.OwnerAccountID, &k.Name, &k.Label, &k.KeyHash, &active,
		&limit, &k.LimitReset, &rpm, &itpm, &otpm,
		&allowed, &expiresAt, &k.CreatedAt, &lastUsedAt, &k.SelfRouteOnly); err != nil {
		return nil, err
	}
	k.Disabled = !active
	k.LimitMicroUSD = limit
	k.RPMLimit = rpm
	k.ITPMLimit = itpm
	k.OTPMLimit = otpm
	k.LimitReset = NormalizeResetWindow(k.LimitReset)
	k.AllowedModels = decodeModelList(allowed)
	k.ExpiresAt = expiresAt
	k.LastUsedAt = lastUsedAt
	return &k, nil
}

// encodeModelList serializes a model allow-list for storage. Empty → "".
func encodeModelList(models []string) string {
	if len(models) == 0 {
		return ""
	}
	b, err := json.Marshal(models)
	if err != nil {
		return ""
	}
	return string(b)
}

// decodeModelList parses a stored model allow-list. "" / invalid → nil.
func decodeModelList(s string) []string {
	if s == "" || s == "[]" {
		return nil
	}
	var out []string
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return nil
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// insertAPIKey writes a fully-formed key record. Shared by CreateAPIKey/SeedKey.
func (s *PostgresStore) insertAPIKey(ctx context.Context, rec *APIKey, onConflictDoNothing bool) error {
	q := `INSERT INTO api_keys
		(id, key_hash, raw_prefix, owner_account_id, name, active,
		 limit_micro_usd, limit_reset, rpm_limit, itpm_limit, otpm_limit,
		 allowed_models, expires_at, created_at, self_route_only)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)`
	if onConflictDoNothing {
		q += ` ON CONFLICT (key_hash) DO NOTHING`
	}
	_, err := s.pool.Exec(ctx, q,
		rec.ID, rec.KeyHash, rec.Label, rec.OwnerAccountID, rec.Name, !rec.Disabled,
		rec.LimitMicroUSD, NormalizeResetWindow(rec.LimitReset), rec.RPMLimit, rec.ITPMLimit, rec.OTPMLimit,
		encodeModelList(rec.AllowedModels), rec.ExpiresAt, rec.CreatedAt, rec.SelfRouteOnly,
	)
	return err
}

// CreateKey generates a cryptographically random API key, hashes it, stores
// the hash, and returns the raw key (the only time it's available in plaintext).
func (s *PostgresStore) CreateKey() (string, error) {
	raw, _, err := s.CreateAPIKey("", APIKeyCreate{})
	return raw, err
}

// CreateKeyForAccount generates a new API key linked to a specific account.
func (s *PostgresStore) CreateKeyForAccount(accountID string) (string, error) {
	raw, _, err := s.CreateAPIKey(accountID, APIKeyCreate{})
	return raw, err
}

// CreateAPIKey mints a new API key with optional per-key limits.
func (s *PostgresStore) CreateAPIKey(accountID string, opts APIKeyCreate) (string, *APIKey, error) {
	raw, err := GenerateRawKey()
	if err != nil {
		return "", nil, fmt.Errorf("store: generate key: %w", err)
	}
	id, err := GenerateKeyID()
	if err != nil {
		return "", nil, fmt.Errorf("store: generate key id: %w", err)
	}
	rec := &APIKey{
		ID:             id,
		OwnerAccountID: accountID,
		Name:           opts.Name,
		Label:          KeyLabel(raw),
		KeyHash:        hashKey(raw),
		LimitMicroUSD:  opts.LimitMicroUSD,
		LimitReset:     NormalizeResetWindow(opts.LimitReset),
		RPMLimit:       opts.RPMLimit,
		ITPMLimit:      opts.ITPMLimit,
		OTPMLimit:      opts.OTPMLimit,
		AllowedModels:  opts.AllowedModels,
		SelfRouteOnly:  opts.SelfRouteOnly,
		ExpiresAt:      opts.ExpiresAt,
		CreatedAt:      time.Now().UTC(),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.insertAPIKey(ctx, rec, false); err != nil {
		return "", nil, fmt.Errorf("store: insert key: %w", err)
	}
	return raw, rec, nil
}

// SeedKey inserts a specific raw key into the database. This is used for
// bootstrapping the admin key. If the key already exists, it is a no-op.
func (s *PostgresStore) SeedKey(rawKey string) error {
	id, err := GenerateKeyID()
	if err != nil {
		return fmt.Errorf("store: generate key id: %w", err)
	}
	rec := &APIKey{
		ID:         id,
		Name:       "admin",
		Label:      KeyLabel(rawKey),
		KeyHash:    hashKey(rawKey),
		LimitReset: KeyResetNone,
		CreatedAt:  time.Now().UTC(),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.insertAPIKey(ctx, rec, true); err != nil {
		return fmt.Errorf("store: seed key: %w", err)
	}
	return nil
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

// ValidateKey returns true if the given key exists, is active, and is not
// expired. Expiry is enforced here (not just in AuthenticateKey) so callers
// like telemetry attribution don't treat an expired key as a live account.
func (s *PostgresStore) ValidateKey(key string) bool {
	h := hashKey(key)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var active bool
	var expiresAt *time.Time
	err := s.pool.QueryRow(ctx,
		`SELECT active, expires_at FROM api_keys WHERE key_hash = $1`,
		h,
	).Scan(&active, &expiresAt)
	if err != nil {
		return false
	}
	if expiresAt != nil && time.Now().After(*expiresAt) {
		return false
	}
	return active
}

// ValidateKeyFull returns the active status and owner account ID for an
// API key in a single query. Returns an error if the key does not exist.
func (s *PostgresStore) ValidateKeyFull(key string) (bool, string, error) {
	h := hashKey(key)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var active bool
	var ownerAccountID string
	err := s.pool.QueryRow(ctx,
		`SELECT active, owner_account_id FROM api_keys WHERE key_hash = $1`, h,
	).Scan(&active, &ownerAccountID)
	if err != nil {
		return false, "", err
	}
	return active, ownerAccountID, nil
}

// AuthenticateKey resolves a raw key to its active record for request auth.
func (s *PostgresStore) AuthenticateKey(rawKey string) (*APIKey, error) {
	h := hashKey(rawKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+apiKeyColumns+` FROM api_keys WHERE key_hash = $1`, h)
	k, err := scanAPIKeyRow(row)
	if err != nil {
		return nil, err
	}
	if k.Disabled {
		return nil, fmt.Errorf("key disabled")
	}
	if k.ExpiresAt != nil && time.Now().After(*k.ExpiresAt) {
		return nil, fmt.Errorf("key expired")
	}
	return k, nil
}

// ListAPIKeys returns all keys owned by an account, newest first.
func (s *PostgresStore) ListAPIKeys(accountID string) ([]APIKey, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+apiKeyColumns+` FROM api_keys WHERE owner_account_id = $1 AND id <> '' ORDER BY created_at DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]APIKey, 0)
	for rows.Next() {
		k, err := scanAPIKeyRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *k)
	}
	return out, rows.Err()
}

// GetAPIKeyByID returns a single key by ID, scoped to the owner.
func (s *PostgresStore) GetAPIKeyByID(accountID, id string) (*APIKey, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+apiKeyColumns+` FROM api_keys WHERE id = $1 AND owner_account_id = $2`, id, accountID)
	return scanAPIKeyRow(row)
}

// UpdateAPIKey overwrites mutable fields of a key, scoped to the owner.
func (s *PostgresStore) UpdateAPIKey(accountID, id string, mutable APIKey) (*APIKey, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx,
		`UPDATE api_keys SET
			name = $1, active = $2, limit_micro_usd = $3, limit_reset = $4,
			rpm_limit = $5, itpm_limit = $6, otpm_limit = $7,
			allowed_models = $8, expires_at = $9, self_route_only = $10
		 WHERE id = $11 AND owner_account_id = $12`,
		mutable.Name, !mutable.Disabled, mutable.LimitMicroUSD, NormalizeResetWindow(mutable.LimitReset),
		mutable.RPMLimit, mutable.ITPMLimit, mutable.OTPMLimit,
		encodeModelList(mutable.AllowedModels), mutable.ExpiresAt, mutable.SelfRouteOnly,
		id, accountID,
	)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		return nil, fmt.Errorf("key not found")
	}
	return s.GetAPIKeyByID(accountID, id)
}

// RevokeAPIKeyByID permanently deletes a key by ID, scoped to the owner.
func (s *PostgresStore) RevokeAPIKeyByID(accountID, id string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`DELETE FROM api_keys WHERE id = $1 AND owner_account_id = $2`, id, accountID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("key not found")
	}
	return nil
}

// RotateAPIKey atomically replaces a key within a transaction (see Store
// interface). The old key is deleted and the new key inserted in the same tx;
// a concurrent rotate of the same id finds the row gone and returns not-found.
func (s *PostgresStore) RotateAPIKey(accountID, id string) (string, *APIKey, error) {
	raw, err := GenerateRawKey()
	if err != nil {
		return "", nil, fmt.Errorf("store: generate key: %w", err)
	}
	newID, err := GenerateKeyID()
	if err != nil {
		return "", nil, fmt.Errorf("store: generate key id: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", nil, fmt.Errorf("store: begin rotate tx: %w", err)
	}
	defer tx.Rollback(ctx)

	old, err := scanAPIKeyRow(tx.QueryRow(ctx,
		`SELECT `+apiKeyColumns+` FROM api_keys WHERE id = $1 AND owner_account_id = $2 FOR UPDATE`, id, accountID))
	if err != nil {
		return "", nil, fmt.Errorf("key not found")
	}

	rec := &APIKey{
		ID:             newID,
		OwnerAccountID: accountID,
		Name:           old.Name,
		Label:          KeyLabel(raw),
		KeyHash:        hashKey(raw),
		Disabled:       old.Disabled,
		LimitMicroUSD:  old.LimitMicroUSD,
		LimitReset:     NormalizeResetWindow(old.LimitReset),
		RPMLimit:       old.RPMLimit,
		ITPMLimit:      old.ITPMLimit,
		OTPMLimit:      old.OTPMLimit,
		AllowedModels:  old.AllowedModels,
		SelfRouteOnly:  old.SelfRouteOnly,
		ExpiresAt:      old.ExpiresAt,
		CreatedAt:      time.Now().UTC(),
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO api_keys
			(id, key_hash, raw_prefix, owner_account_id, name, active,
			 limit_micro_usd, limit_reset, rpm_limit, itpm_limit, otpm_limit,
			 allowed_models, expires_at, created_at, self_route_only)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)`,
		rec.ID, rec.KeyHash, rec.Label, rec.OwnerAccountID, rec.Name, !rec.Disabled,
		rec.LimitMicroUSD, rec.LimitReset, rec.RPMLimit, rec.ITPMLimit, rec.OTPMLimit,
		encodeModelList(rec.AllowedModels), rec.ExpiresAt, rec.CreatedAt, rec.SelfRouteOnly,
	); err != nil {
		return "", nil, fmt.Errorf("store: insert rotated key: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM api_keys WHERE id = $1 AND owner_account_id = $2`, id, accountID); err != nil {
		return "", nil, fmt.Errorf("store: delete old key: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return "", nil, fmt.Errorf("store: commit rotate: %w", err)
	}
	return raw, rec, nil
}

// TouchAPIKey records that a key was used at the given time.
func (s *PostgresStore) TouchAPIKey(id string, at time.Time) {
	if id == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, _ = s.pool.Exec(ctx, `UPDATE api_keys SET last_used_at = $1 WHERE id = $2`, at.UTC(), id)
}

// KeySpendSince returns total micro-USD charged to a key since `since` (UTC).
func (s *PostgresStore) KeySpendSince(keyID string, since time.Time) int64 {
	if keyID == "" {
		return 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var total int64
	err := s.pool.QueryRow(ctx,
		`SELECT COALESCE(SUM(cost_micro_usd), 0) FROM usage
		 WHERE key_id = $1 AND ($2::timestamptz IS NULL OR created_at >= $2)`,
		keyID, nullSince(since),
	).Scan(&total)
	if err != nil {
		return 0
	}
	return total
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
		`WITH ins AS (
			INSERT INTO usage (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens)
			VALUES ($1, $2, $3, $4, $5)
		)
		UPDATE usage_totals SET
			total_requests = total_requests + 1,
			total_prompt_tokens = total_prompt_tokens + $4,
			total_completion_tokens = total_completion_tokens + $5
		WHERE id = 1`,
		providerID, h, model, promptTokens, completionTokens,
	)
}

// UsageByConsumer returns usage records for a specific consumer key.
func (s *PostgresStore) UsageByConsumer(consumerKey string) []UsageRecord {
	h := hashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, completion_tokens, created_at, request_id, cost_micro_usd
			 FROM usage WHERE consumer_key_hash = $1 ORDER BY created_at DESC LIMIT 100`, h)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		if err := rows.Scan(&r.ProviderID, &r.ConsumerKey, &r.Model, &r.PublicModel, &r.PromptTokens, &r.CompletionTokens, &r.CreatedAt, &r.RequestID, &r.CostMicroUSD); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}

// RecordUsageWithCost inserts a usage record with request ID and cost.
func (s *PostgresStore) RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64) {
	s.RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID, promptTokens, completionTokens, costMicroUSD, nil)
}

// RecordUsageWithCostAndLocation inserts a usage record with request ID, cost,
// and approximate request-origin location.
func (s *PostgresStore) RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	s.RecordUsageFull(providerID, consumerKey, "", model, requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFull inserts a usage record with full attribution including the
// originating API key ID for per-key usage and spend tracking.
func (s *PostgresStore) RecordUsageFull(providerID, consumerKey, keyID, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	s.RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, "", requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFullWithPublicModel inserts a usage record with full attribution,
// storing both the concrete billing model and optional public display model.
func (s *PostgresStore) RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, publicModel, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	h := hashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, _ = s.pool.Exec(ctx,
		`WITH ins AS (
			INSERT INTO usage (provider_id, consumer_key_hash, key_id, model, public_model, prompt_tokens, completion_tokens, request_id, cost_micro_usd, request_location)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		)
		UPDATE usage_totals SET
			total_requests = total_requests + 1,
			total_prompt_tokens = total_prompt_tokens + $6,
			total_completion_tokens = total_completion_tokens + $7
		WHERE id = 1`,
		providerID, h, keyID, model, publicModel, promptTokens, completionTokens, requestID, costMicroUSD, marshalProviderLocation(requestLocation),
	)
}

const inferenceRouteErrorReasonUpsertAssignment = "error_reason = COALESCE(NULLIF(EXCLUDED.error_reason, ''), inference_routes.error_reason)"

const inferenceRouteSelectColumns = `
			id,
			request_id, attempt, provider_id, model, public_model, consumer_key_hash, key_id, outcome,
			cost_ms, state_ms, queue_ms, pending_ms, backlog_ms, this_req_ms, health_ms, ttft_ms, best_ttft_ms,
			effective_queue, candidate_count, capacity_rejections, model_too_large_rejections, vision_rejections, ttft_rejections,
			effective_tps, static_tps, provider_status, provider_trust_level, provider_version,
			hardware_chip, hardware_chip_family, hardware_tier, memory_gb, gpu_cores, cpu_cores,
			system_memory_pressure, system_cpu_usage, system_thermal_state,
			gpu_memory_active_gb, gpu_memory_peak_gb, gpu_memory_cache_gb,
			slot_state, backend_running, backend_waiting,
			active_token_budget_used, active_token_budget_max, queued_token_budget,
			estimated_prompt_tokens, requested_max_tokens,
			requires_vision, has_tools, self_route_only, prefer_owner, cache_affinity_key,
			final_status, error_code, error_class, prompt_tokens, completion_tokens, reasoning_tokens, cost_micro_usd,
			actual_ttft_ms, dispatch_to_first_chunk_ms, total_duration_ms,
			created_at, updated_at,
			provider_region, consumer_region,
			parse_ms, reserve_ms, route_ms, encrypt_ms, queue_wait_ms, dispatch_ms, actual_decode_tps,
			admitted_but_failed, used_backup, backup_won, error_reason`

// RecordInferenceRoute writes the routing decision snapshot for a request
// attempt. Callers keep this best-effort by logging returned errors off the
// request path rather than blocking inference.
func (s *PostgresStore) RecordInferenceRoute(record *InferenceRouteRecord) error {
	if record == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	now := time.Now().UTC()
	createdAt := record.CreatedAt
	if createdAt.IsZero() {
		createdAt = now
	}
	updatedAt := record.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = now
	}

	_, err := s.pool.Exec(ctx,
		`INSERT INTO inference_routes (
			request_id, attempt, provider_id, model, public_model, consumer_key_hash, key_id, outcome,
			cost_ms, state_ms, queue_ms, pending_ms, backlog_ms, this_req_ms, health_ms, ttft_ms, best_ttft_ms,
			effective_queue, candidate_count, capacity_rejections, model_too_large_rejections, vision_rejections, ttft_rejections,
			effective_tps, static_tps, provider_status, provider_trust_level, provider_version,
			hardware_chip, hardware_chip_family, hardware_tier, memory_gb, gpu_cores, cpu_cores,
			system_memory_pressure, system_cpu_usage, system_thermal_state,
			gpu_memory_active_gb, gpu_memory_peak_gb, gpu_memory_cache_gb,
			slot_state, backend_running, backend_waiting,
			active_token_budget_used, active_token_budget_max, queued_token_budget,
			estimated_prompt_tokens, requested_max_tokens,
			requires_vision, has_tools, self_route_only, prefer_owner, cache_affinity_key,
			created_at, updated_at,
			provider_region, consumer_region, error_reason
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8,
			$9, $10, $11, $12, $13, $14, $15, $16, $17,
			$18, $19, $20, $21, $22, $23,
			$24, $25, $26, $27, $28,
			$29, $30, $31, $32, $33, $34,
			$35, $36, $37,
			$38, $39, $40,
			$41, $42, $43,
			$44, $45, $46,
			$47, $48,
			$49, $50, $51, $52, $53,
			$54, $55,
			$56, $57, $58
		) ON CONFLICT (request_id, attempt) DO UPDATE SET
			provider_id = EXCLUDED.provider_id,
			model = EXCLUDED.model,
			public_model = EXCLUDED.public_model,
			consumer_key_hash = EXCLUDED.consumer_key_hash,
			key_id = EXCLUDED.key_id,
			outcome = EXCLUDED.outcome,
			cost_ms = EXCLUDED.cost_ms,
			state_ms = EXCLUDED.state_ms,
			queue_ms = EXCLUDED.queue_ms,
			pending_ms = EXCLUDED.pending_ms,
			backlog_ms = EXCLUDED.backlog_ms,
			this_req_ms = EXCLUDED.this_req_ms,
			health_ms = EXCLUDED.health_ms,
			ttft_ms = EXCLUDED.ttft_ms,
			best_ttft_ms = EXCLUDED.best_ttft_ms,
			effective_queue = EXCLUDED.effective_queue,
			candidate_count = EXCLUDED.candidate_count,
			capacity_rejections = EXCLUDED.capacity_rejections,
			model_too_large_rejections = EXCLUDED.model_too_large_rejections,
			vision_rejections = EXCLUDED.vision_rejections,
			ttft_rejections = EXCLUDED.ttft_rejections,
			effective_tps = EXCLUDED.effective_tps,
			static_tps = EXCLUDED.static_tps,
			provider_status = EXCLUDED.provider_status,
			provider_trust_level = EXCLUDED.provider_trust_level,
			provider_version = EXCLUDED.provider_version,
			hardware_chip = EXCLUDED.hardware_chip,
			hardware_chip_family = EXCLUDED.hardware_chip_family,
			hardware_tier = EXCLUDED.hardware_tier,
			memory_gb = EXCLUDED.memory_gb,
			gpu_cores = EXCLUDED.gpu_cores,
			cpu_cores = EXCLUDED.cpu_cores,
			system_memory_pressure = EXCLUDED.system_memory_pressure,
			system_cpu_usage = EXCLUDED.system_cpu_usage,
			system_thermal_state = EXCLUDED.system_thermal_state,
			gpu_memory_active_gb = EXCLUDED.gpu_memory_active_gb,
			gpu_memory_peak_gb = EXCLUDED.gpu_memory_peak_gb,
			gpu_memory_cache_gb = EXCLUDED.gpu_memory_cache_gb,
			slot_state = EXCLUDED.slot_state,
			backend_running = EXCLUDED.backend_running,
			backend_waiting = EXCLUDED.backend_waiting,
			active_token_budget_used = EXCLUDED.active_token_budget_used,
			active_token_budget_max = EXCLUDED.active_token_budget_max,
			queued_token_budget = EXCLUDED.queued_token_budget,
			estimated_prompt_tokens = EXCLUDED.estimated_prompt_tokens,
			requested_max_tokens = EXCLUDED.requested_max_tokens,
			requires_vision = EXCLUDED.requires_vision,
			has_tools = EXCLUDED.has_tools,
			self_route_only = EXCLUDED.self_route_only,
			prefer_owner = EXCLUDED.prefer_owner,
			cache_affinity_key = EXCLUDED.cache_affinity_key,
			provider_region = EXCLUDED.provider_region,
			consumer_region = EXCLUDED.consumer_region,
			`+inferenceRouteErrorReasonUpsertAssignment+`,
			updated_at = EXCLUDED.updated_at`,
		record.RequestID, record.Attempt, record.ProviderID, record.Model, record.PublicModel, record.ConsumerKeyHash, record.KeyID, record.Outcome,
		record.CostMs, record.StateMs, record.QueueMs, record.PendingMs, record.BacklogMs, record.ThisReqMs, record.HealthMs, record.TTFTMs, record.BestTTFTMs,
		record.EffectiveQueue, record.CandidateCount, record.CapacityRejections, record.ModelTooLargeRejections, record.VisionRejections, record.TTFTRejections,
		record.EffectiveTPS, record.StaticTPS, record.ProviderStatus, record.ProviderTrustLevel, record.ProviderVersion,
		record.HardwareChip, record.HardwareChipFamily, record.HardwareTier, record.MemoryGB, record.GPUCores, record.CPUCores,
		record.SystemMemoryPressure, record.SystemCPUUsage, record.SystemThermalState,
		record.GPUMemoryActiveGB, record.GPUMemoryPeakGB, record.GPUMemoryCacheGB,
		record.SlotState, record.BackendRunning, record.BackendWaiting,
		record.ActiveTokenBudgetUsed, record.ActiveTokenBudgetMax, record.QueuedTokenBudget,
		record.EstimatedPromptTokens, record.RequestedMaxTokens,
		record.RequiresVision, record.HasTools, record.SelfRouteOnly, record.PreferOwner, record.CacheAffinityKey,
		createdAt, updatedAt,
		record.ProviderRegion, record.ConsumerRegion, record.ErrorReason,
	)
	if err != nil {
		return fmt.Errorf("store: record inference route: %w", err)
	}
	return nil
}

// UpdateInferenceRouteOutcome updates the attempt with final outcome data
// (tokens, timing, error). Callers keep this best-effort by logging returned
// errors off the request path rather than blocking inference.
func (s *PostgresStore) UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *InferenceRouteOutcome) error {
	if outcome == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE inference_routes SET
			final_status = COALESCE(NULLIF($3, ''), final_status),
			error_code = CASE WHEN $4 <> 0 THEN $4 ELSE error_code END,
			error_class = COALESCE(NULLIF($5, ''), error_class),
			error_reason = COALESCE(NULLIF($6, ''), error_reason),
			prompt_tokens = CASE WHEN $7 <> 0 THEN $7 ELSE prompt_tokens END,
			-- $24 (CompletionTokensSet) force-writes the count even when 0 so a
			-- terminal cancel/error/timeout row persists 0 instead of NULL; the
			-- OR $8 <> 0 keeps the legacy non-zero write path (mirrors the memory
			-- store's mergeInferenceRouteOutcome exactly).
			completion_tokens = CASE WHEN $24 OR $8 <> 0 THEN $8 ELSE completion_tokens END,
			reasoning_tokens = CASE WHEN $9 <> 0 THEN $9 ELSE reasoning_tokens END,
			cost_micro_usd = CASE WHEN $10 <> 0 THEN $10 ELSE cost_micro_usd END,
			actual_ttft_ms = CASE WHEN $11 <> 0 THEN $11 ELSE actual_ttft_ms END,
			dispatch_to_first_chunk_ms = CASE WHEN $12 <> 0 THEN $12 ELSE dispatch_to_first_chunk_ms END,
			total_duration_ms = CASE WHEN $13 <> 0 THEN $13 ELSE total_duration_ms END,
			parse_ms = CASE WHEN $14 <> 0 THEN $14 ELSE parse_ms END,
			reserve_ms = CASE WHEN $15 <> 0 THEN $15 ELSE reserve_ms END,
			route_ms = CASE WHEN $16 <> 0 THEN $16 ELSE route_ms END,
			encrypt_ms = CASE WHEN $17 <> 0 THEN $17 ELSE encrypt_ms END,
			queue_wait_ms = CASE WHEN $18 <> 0 THEN $18 ELSE queue_wait_ms END,
			dispatch_ms = CASE WHEN $19 <> 0 THEN $19 ELSE dispatch_ms END,
			actual_decode_tps = CASE WHEN $20 <> 0 THEN $20 ELSE actual_decode_tps END,
			admitted_but_failed = COALESCE(admitted_but_failed, FALSE) OR $21,
			used_backup = COALESCE(used_backup, FALSE) OR $22,
			backup_won = COALESCE(backup_won, FALSE) OR $23,
			updated_at = NOW()
		 WHERE request_id = $1 AND attempt = $2`,
		requestID, attempt,
		outcome.FinalStatus, outcome.ErrorCode, outcome.ErrorClass, outcome.ErrorReason, outcome.PromptTokens, outcome.CompletionTokens, outcome.ReasoningTokens,
		outcome.CostMicroUSD, outcome.ActualTTFTMs, outcome.DispatchToFirstChunkMs, outcome.TotalDurationMs,
		outcome.ParseMs, outcome.ReserveMs, outcome.RouteMs, outcome.EncryptMs, outcome.QueueWaitMs, outcome.DispatchMs, outcome.ActualDecodeTPS,
		outcome.AdmittedButFailed, outcome.UsedBackup, outcome.BackupWon,
		outcome.CompletionTokensSet,
	)
	if err != nil {
		return fmt.Errorf("store: update inference route outcome: %w", err)
	}
	return nil
}

// InferenceRouteRecordsSince returns routing records created at or after the
// given time. Zero since returns all records.
func (s *PostgresStore) InferenceRouteRecordsSince(since time.Time) []InferenceRouteRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+inferenceRouteSelectColumns+` FROM inference_routes WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		since, maxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []InferenceRouteRecord
	for rows.Next() {
		var r InferenceRouteRecord
		var id int64
		var finalStatus string
		var errorCode *int
		var errorClass *string
		var errorReason *string
		var promptTokens *int
		var completionTokens *int
		var reasoningTokens *int
		var costMicroUSD *int64
		var actualTTFTMs *float64
		var dispatchToFirstChunkMs *float64
		var totalDurationMs *float64
		var providerRegion *string
		var consumerRegion *string
		var parseMs *float64
		var reserveMs *float64
		var routeMs *float64
		var encryptMs *float64
		var queueWaitMs *float64
		var dispatchMs *float64
		var actualDecodeTPS *float64
		var admittedButFailed *bool
		var usedBackup *bool
		var backupWon *bool

		if err := rows.Scan(
			&id,
			&r.RequestID, &r.Attempt, &r.ProviderID, &r.Model, &r.PublicModel, &r.ConsumerKeyHash, &r.KeyID, &r.Outcome,
			&r.CostMs, &r.StateMs, &r.QueueMs, &r.PendingMs, &r.BacklogMs, &r.ThisReqMs, &r.HealthMs, &r.TTFTMs, &r.BestTTFTMs,
			&r.EffectiveQueue, &r.CandidateCount, &r.CapacityRejections, &r.ModelTooLargeRejections, &r.VisionRejections, &r.TTFTRejections,
			&r.EffectiveTPS, &r.StaticTPS, &r.ProviderStatus, &r.ProviderTrustLevel, &r.ProviderVersion,
			&r.HardwareChip, &r.HardwareChipFamily, &r.HardwareTier, &r.MemoryGB, &r.GPUCores, &r.CPUCores,
			&r.SystemMemoryPressure, &r.SystemCPUUsage, &r.SystemThermalState,
			&r.GPUMemoryActiveGB, &r.GPUMemoryPeakGB, &r.GPUMemoryCacheGB,
			&r.SlotState, &r.BackendRunning, &r.BackendWaiting,
			&r.ActiveTokenBudgetUsed, &r.ActiveTokenBudgetMax, &r.QueuedTokenBudget,
			&r.EstimatedPromptTokens, &r.RequestedMaxTokens,
			&r.RequiresVision, &r.HasTools, &r.SelfRouteOnly, &r.PreferOwner, &r.CacheAffinityKey,
			&finalStatus, &errorCode, &errorClass, &promptTokens, &completionTokens, &reasoningTokens, &costMicroUSD,
			&actualTTFTMs, &dispatchToFirstChunkMs, &totalDurationMs,
			&r.CreatedAt, &r.UpdatedAt,
			&providerRegion, &consumerRegion,
			&parseMs, &reserveMs, &routeMs, &encryptMs, &queueWaitMs, &dispatchMs, &actualDecodeTPS,
			&admittedButFailed, &usedBackup, &backupWon, &errorReason,
		); err != nil {
			continue
		}
		if providerRegion != nil {
			r.ProviderRegion = *providerRegion
		}
		if consumerRegion != nil {
			r.ConsumerRegion = *consumerRegion
		}
		outcome := InferenceRouteOutcome{FinalStatus: finalStatus}
		if errorCode != nil {
			outcome.ErrorCode = *errorCode
		}
		if errorClass != nil {
			outcome.ErrorClass = *errorClass
		}
		if errorReason != nil {
			outcome.ErrorReason = *errorReason
		}
		if promptTokens != nil {
			outcome.PromptTokens = *promptTokens
		}
		if completionTokens != nil {
			outcome.CompletionTokens = *completionTokens
		}
		if reasoningTokens != nil {
			outcome.ReasoningTokens = *reasoningTokens
		}
		if costMicroUSD != nil {
			outcome.CostMicroUSD = *costMicroUSD
		}
		if actualTTFTMs != nil {
			outcome.ActualTTFTMs = *actualTTFTMs
		}
		if dispatchToFirstChunkMs != nil {
			outcome.DispatchToFirstChunkMs = *dispatchToFirstChunkMs
		}
		if totalDurationMs != nil {
			outcome.TotalDurationMs = *totalDurationMs
		}
		if parseMs != nil {
			outcome.ParseMs = *parseMs
		}
		if reserveMs != nil {
			outcome.ReserveMs = *reserveMs
		}
		if routeMs != nil {
			outcome.RouteMs = *routeMs
		}
		if encryptMs != nil {
			outcome.EncryptMs = *encryptMs
		}
		if queueWaitMs != nil {
			outcome.QueueWaitMs = *queueWaitMs
		}
		if dispatchMs != nil {
			outcome.DispatchMs = *dispatchMs
		}
		if actualDecodeTPS != nil {
			outcome.ActualDecodeTPS = *actualDecodeTPS
		}
		if admittedButFailed != nil {
			outcome.AdmittedButFailed = *admittedButFailed
		}
		if usedBackup != nil {
			outcome.UsedBackup = *usedBackup
		}
		if backupWon != nil {
			outcome.BackupWon = *backupWon
		}
		applyInferenceRouteOutcomeToRecord(&r, outcome)
		records = append(records, r)
	}
	return records
}

// RecordRejection writes a rejected-request record with its counterfactual
// servability snapshot. Best-effort; failures are discarded and never block
// the request path.
func (s *PostgresStore) RecordRejection(record *RejectionRecord) error {
	if record == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	createdAt := record.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	}

	// Mirror marshalProviderLocation's JSONB handling: pass nil (→ SQL NULL)
	// when there are no params so we never write an invalid empty JSONB value.
	var params json.RawMessage
	if len(record.Params) > 0 {
		params = record.Params
	}

	_, _ = s.pool.Exec(ctx,
		`INSERT INTO request_rejections (
			request_id, endpoint, stage, reason_code, http_status, consumer_key_hash, key_id, client_class,
			requested_model, resolved_model, stream, n, estimated_prompt_tokens, requested_max_tokens,
			requires_vision, has_image, has_audio, has_tools, tool_count, response_format, self_route_only, prefer_owner,
			params, request_body_bytes, retry_after_ms,
			could_have_served, candidate_count, capacity_rejections, model_too_large_rejections, vision_rejections,
			warm_provider_existed, best_ttft_ms, shortfall_micro_usd, limit_kind, over_by,
			created_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8,
			$9, $10, $11, $12, $13, $14,
			$15, $16, $17, $18, $19, $20, $21, $22,
			$23, $24, $25,
			$26, $27, $28, $29, $30,
			$31, $32, $33, $34, $35,
			$36
		)`,
		record.RequestID, record.Endpoint, record.Stage, record.ReasonCode, record.HTTPStatus, record.ConsumerKeyHash, record.KeyID, record.ClientClass,
		record.RequestedModel, record.ResolvedModel, record.Stream, record.N, record.EstimatedPromptTokens, record.RequestedMaxTokens,
		record.RequiresVision, record.HasImage, record.HasAudio, record.HasTools, record.ToolCount, record.ResponseFormat, record.SelfRouteOnly, record.PreferOwner,
		params, record.RequestBodyBytes, record.RetryAfterMs,
		record.CouldHaveServed, record.CandidateCount, record.CapacityRejections, record.ModelTooLargeRejections, record.VisionRejections,
		record.WarmProviderExisted, record.BestTTFTMs, record.ShortfallMicroUSD, record.LimitKind, record.OverBy,
		createdAt,
	)
	return nil
}

// RejectionRecordsSince returns rejection records created at or after the given
// time. Zero since returns all records.
func (s *PostgresStore) RejectionRecordsSince(since time.Time) []RejectionRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT * FROM request_rejections WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		since, maxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []RejectionRecord
	for rows.Next() {
		var r RejectionRecord
		var id int64
		var paramsRaw []byte

		if err := rows.Scan(
			&id,
			&r.RequestID, &r.Endpoint, &r.Stage, &r.ReasonCode, &r.HTTPStatus, &r.ConsumerKeyHash, &r.KeyID, &r.ClientClass,
			&r.RequestedModel, &r.ResolvedModel, &r.Stream, &r.N, &r.EstimatedPromptTokens, &r.RequestedMaxTokens,
			&r.RequiresVision, &r.HasImage, &r.HasAudio, &r.HasTools, &r.ToolCount, &r.ResponseFormat, &r.SelfRouteOnly, &r.PreferOwner,
			&paramsRaw, &r.RequestBodyBytes, &r.RetryAfterMs,
			&r.CouldHaveServed, &r.CandidateCount, &r.CapacityRejections, &r.ModelTooLargeRejections, &r.VisionRejections,
			&r.WarmProviderExisted, &r.BestTTFTMs, &r.ShortfallMicroUSD, &r.LimitKind, &r.OverBy,
			&r.CreatedAt,
		); err != nil {
			continue
		}
		if len(paramsRaw) > 0 {
			r.Params = paramsRaw
		}
		records = append(records, r)
	}
	return records
}

// UsageLocationBuckets aggregates usage by approximate request origin.
func (s *PostgresStore) UsageLocationBuckets(since time.Time) []UsageLocationBucket {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT
			COALESCE(request_location->>'city', '') AS city,
			COALESCE(request_location->>'region', '') AS region,
			COALESCE(request_location->>'region_code', '') AS region_code,
			COALESCE(request_location->>'country', '') AS country,
			COALESCE(request_location->>'country_code', '') AS country_code,
			COALESCE(AVG(NULLIF(request_location->>'latitude', '')::double precision), 0),
			COALESCE(AVG(NULLIF(request_location->>'longitude', '')::double precision), 0),
			COUNT(*),
			COALESCE(SUM(prompt_tokens), 0),
			COALESCE(SUM(completion_tokens), 0),
			COUNT(DISTINCT provider_id)
		 FROM usage
		 WHERE request_location IS NOT NULL
		   AND ($1::timestamptz IS NULL OR created_at >= $1)
		 GROUP BY city, region, region_code, country, country_code
		 ORDER BY COUNT(*) DESC`,
		nullSince(since),
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var buckets []UsageLocationBucket
	for rows.Next() {
		var b UsageLocationBucket
		if err := rows.Scan(
			&b.City,
			&b.Region,
			&b.RegionCode,
			&b.Country,
			&b.CountryCode,
			&b.Latitude,
			&b.Longitude,
			&b.Requests,
			&b.PromptTokens,
			&b.CompletionTokens,
			&b.Providers,
		); err != nil {
			continue
		}
		buckets = append(buckets, b)
	}
	return buckets
}

// UsageFlowBuckets aggregates directional consumer→provider flows by JOINing
// the usage table with providers in SQL. This replaces loading all rows into
// Go and doing the aggregation in-process. The query only returns the top 50
// flows (by request count) so the result set is bounded.
func (s *PostgresStore) UsageFlowBuckets(since time.Time, _ map[string]*ProviderLocation) []UsageFlowBucket {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT
			COALESCE(u.request_location->>'city', '')         AS c_city,
			COALESCE(u.request_location->>'region', '')       AS c_region,
			COALESCE(u.request_location->>'region_code', '')  AS c_region_code,
			COALESCE(u.request_location->>'country', '')      AS c_country,
			COALESCE(u.request_location->>'country_code', '') AS c_country_code,
			COALESCE(AVG(NULLIF(u.request_location->>'latitude',  '')::double precision), 0) AS c_lat,
			COALESCE(AVG(NULLIF(u.request_location->>'longitude', '')::double precision), 0) AS c_lng,
			COALESCE(p.location->>'city', '')         AS p_city,
			COALESCE(p.location->>'region', '')       AS p_region,
			COALESCE(p.location->>'region_code', '')  AS p_region_code,
			COALESCE(p.location->>'country', '')      AS p_country,
			COALESCE(p.location->>'country_code', '') AS p_country_code,
			COALESCE(AVG(NULLIF(p.location->>'latitude',  '')::double precision), 0) AS p_lat,
			COALESCE(AVG(NULLIF(p.location->>'longitude', '')::double precision), 0) AS p_lng,
			COUNT(*)                              AS requests,
			COALESCE(SUM(u.prompt_tokens), 0)     AS prompt_tokens,
			COALESCE(SUM(u.completion_tokens), 0) AS completion_tokens
		 FROM usage u
		 JOIN providers p ON p.id = u.provider_id
		 WHERE u.request_location IS NOT NULL
		   AND p.location IS NOT NULL
		   AND ($1::timestamptz IS NULL OR u.created_at >= $1)
		 GROUP BY c_city, c_region, c_region_code, c_country, c_country_code,
		          p_city, p_region, p_region_code, p_country, p_country_code
		 ORDER BY requests DESC
		 LIMIT 50`,
		nullSince(since),
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var buckets []UsageFlowBucket
	for rows.Next() {
		var b UsageFlowBucket
		if err := rows.Scan(
			&b.ConsumerCity, &b.ConsumerRegion, &b.ConsumerRegionCode,
			&b.ConsumerCountry, &b.ConsumerCountryCode,
			&b.ConsumerLatitude, &b.ConsumerLongitude,
			&b.ProviderCity, &b.ProviderRegion, &b.ProviderRegionCode,
			&b.ProviderCountry, &b.ProviderCountryCode,
			&b.ProviderLatitude, &b.ProviderLongitude,
			&b.Requests, &b.PromptTokens, &b.CompletionTokens,
		); err != nil {
			continue
		}
		buckets = append(buckets, b)
	}
	return buckets
}

func nullSince(since time.Time) any {
	if since.IsZero() {
		return nil
	}
	return since
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

// UsageCountSince returns the number of usage records created at or after the
// given time. Uses idx_usage_created for an index-only count.
func (s *PostgresStore) UsageCountSince(since time.Time) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var count int64
	_ = s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM usage
		 WHERE ($1::timestamptz IS NULL OR created_at >= $1)`,
		nullSince(since),
	).Scan(&count)
	return count
}

// UsageTotals returns aggregated lifetime totals from the materialized
// usage_totals counter row. This is a single PK lookup — O(1) regardless
// of how many rows exist in the usage table.
func (s *PostgresStore) UsageTotals() UsageTotals {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t UsageTotals
	_ = s.pool.QueryRow(ctx,
		`SELECT total_requests, total_prompt_tokens, total_completion_tokens
		 FROM usage_totals WHERE id = 1`,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens)
	return t
}

// UsageTotalsSince returns aggregate usage at or after `since`.
func (s *PostgresStore) UsageTotalsSince(since time.Time) UsageTotals {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t UsageTotals
	_ = s.pool.QueryRow(ctx,
		`SELECT COUNT(*),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM usage
		 WHERE created_at >= $1`,
		since,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens)
	return t
}

// UsageTimeSeries returns usage buckets at or after `since` using a bounded,
// caller-selected interval so long windows do not return tens of thousands of
// minute rows.
func (s *PostgresStore) UsageTimeSeries(since, until time.Time, bucketSize time.Duration) []UsageBucket {
	since, until, bucketSize = normalizeUsageTimeSeriesRequest(since, until, bucketSize, time.Now())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`WITH bounded AS (
		   SELECT to_timestamp(
		            floor(extract(epoch FROM created_at) / $3::double precision) * $3::double precision
		          ) AS bucket_start,
		          COUNT(*) AS requests,
		          COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
		          COALESCE(SUM(completion_tokens), 0) AS completion_tokens
		   FROM usage
		   WHERE created_at >= $1 AND created_at < $2
		   GROUP BY 1
		   ORDER BY 1 DESC
		   LIMIT $4
		 )
		 SELECT bucket_start, requests, prompt_tokens, completion_tokens
		 FROM bounded
		 ORDER BY bucket_start ASC`,
		since,
		until,
		bucketSize.Seconds(),
		usageTimeSeriesMaxBuckets,
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
	return limitUsageTimeSeriesBuckets(buckets)
}

// rewardLedgerTypesSQLList renders RewardLedgerTypes as a comma-separated list
// of single-quoted SQL string literals (e.g. "'referral_reward','admin_reward'")
// for use in an IN (...) clause. The values are package constants, never user
// input, so literal interpolation here is safe from SQL injection.
func rewardLedgerTypesSQLList() string {
	out := ""
	for i, t := range RewardLedgerTypes {
		if i > 0 {
			out += ","
		}
		out += "'" + string(t) + "'"
	}
	return out
}

// Leaderboard returns the top N accounts ranked by the given metric over the
// given time window. Base-reward rows live in provider_earnings for
// provider-facing history, but count as reward earnings here so they do not
// inflate inference work/jobs/tokens. Ledger reward-only accounts (e.g.
// consumer-only referrers) never appear on the provider leaderboard.
func (s *PostgresStore) Leaderboard(metric LeaderboardMetric, since time.Time, limit int) []LeaderboardRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if limit <= 0 || limit > 200 {
		limit = 50
	}

	orderCol := "earnings_micro_usd"
	switch metric {
	case LeaderboardTokens:
		orderCol = "tokens"
	case LeaderboardJobs:
		orderCol = "jobs"
	}

	// `since` is bound once as $1 and referenced in both CTEs; `limit` is the
	// final positional arg. account_id != '' filters out unassigned earnings.
	args := []any{}
	workWhere := ` WHERE account_id != '' AND model <> 'base_reward'`
	baseRewardWhere := ` WHERE account_id != '' AND model = 'base_reward'`
	rewardSince := ""
	if !since.IsZero() {
		args = append(args, since)
		workWhere += ` AND created_at >= $1`
		baseRewardWhere += ` AND created_at >= $1`
		rewardSince = ` AND created_at >= $1`
	}

	q := `WITH work AS (
	          SELECT account_id,
		                 SUM(amount_micro_usd)                  AS work_micro,
		                 SUM(prompt_tokens + completion_tokens) AS tokens,
		                 COUNT(*)                               AS jobs
		          FROM provider_earnings` + workWhere + `
		          GROUP BY account_id
		      ),
		      base_reward AS (
	          SELECT account_id,
	                 SUM(amount_micro_usd) AS reward_micro
	          FROM provider_earnings` + baseRewardWhere + `
	          GROUP BY account_id
	      ),
	      reward AS (
	          SELECT account_id,
	                 SUM(amount_micro_usd) AS reward_micro
	          FROM ledger_entries
	          WHERE account_id != '' AND entry_type IN (` + rewardLedgerTypesSQLList() + `)` + rewardSince + `
	          GROUP BY account_id
	      )
	      SELECT COALESCE(w.account_id, br.account_id)  AS account_id,
	             COALESCE(w.work_micro,0) + COALESCE(br.reward_micro,0) + COALESCE(r.reward_micro,0) AS earnings_micro_usd,
	             COALESCE(w.work_micro,0)                AS work_micro_usd,
	             COALESCE(br.reward_micro,0) + COALESCE(r.reward_micro,0) AS reward_micro_usd,
	             COALESCE(w.tokens,0)                    AS tokens,
	             COALESCE(w.jobs,0)                      AS jobs
	      FROM work w
	      FULL OUTER JOIN base_reward br ON br.account_id = w.account_id
	      LEFT JOIN reward r ON r.account_id = COALESCE(w.account_id, br.account_id)
	      WHERE COALESCE(w.account_id, br.account_id) IS NOT NULL
	      ORDER BY ` + orderCol + ` DESC, account_id ASC
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
		if err := rows.Scan(&r.AccountID, &r.EarningsMicroUSD, &r.WorkEarningsMicroUSD, &r.RewardEarningsMicroUSD, &r.Tokens, &r.Jobs); err != nil {
			continue
		}
		out = append(out, r)
	}
	return out
}

// NetworkTotals returns aggregated metrics across all earnings for the given
// time window. Zero `since` means all-time. Totals combine inference work
// (provider_earnings) with non-inference reward ledger entries (referral_reward,
// admin_reward), but rewards are only counted for provider accounts (those with
// inference work in the window) so consumer-only reward recipients don't inflate
// network provider totals. ActiveAccounts counts distinct provider accounts.
func (s *PostgresStore) NetworkTotals(since time.Time) NetworkTotalsRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// `since`, when set, is bound once as $1 and referenced in the work,
	// base_reward, providers, and reward subqueries.
	args := []any{}
	workWhere := ` WHERE model <> 'base_reward'`
	baseRewardWhere := ` WHERE model = 'base_reward'`
	providerSince := ""
	rewardSince := ""
	if !since.IsZero() {
		args = append(args, since)
		workWhere += ` AND created_at >= $1`
		baseRewardWhere += ` AND created_at >= $1`
		providerSince = ` AND created_at >= $1`
		rewardSince = ` AND le.created_at >= $1`
	}

	rewardTypes := rewardLedgerTypesSQLList()
	q := `WITH work AS (
	          SELECT COALESCE(SUM(amount_micro_usd),0)                  AS work_micro,
	                 COALESCE(SUM(prompt_tokens + completion_tokens),0) AS tokens,
		                 COUNT(*)                                           AS jobs
		          FROM provider_earnings` + workWhere + `
		      ),
		      base_reward AS (
		          SELECT COALESCE(SUM(amount_micro_usd),0) AS reward_micro
		          FROM provider_earnings` + baseRewardWhere + `
		      ),
		      providers AS (
		          SELECT DISTINCT account_id FROM provider_earnings WHERE account_id != ''` + providerSince + `
	      ),
	      reward AS (
	          SELECT COALESCE(SUM(le.amount_micro_usd),0) AS reward_micro
	          FROM ledger_entries le
	          JOIN providers p ON p.account_id = le.account_id
	          WHERE le.entry_type IN (` + rewardTypes + `)` + rewardSince + `
	      )
	      SELECT work.work_micro + base_reward.reward_micro + reward.reward_micro AS earnings_micro,
	             work.work_micro, base_reward.reward_micro + reward.reward_micro, work.tokens, work.jobs,
	             (SELECT COUNT(*) FROM providers)        AS active_accounts
	      FROM work, base_reward, reward`

	var t NetworkTotalsRow
	_ = s.pool.QueryRow(ctx, q, args...).
		Scan(&t.EarningsMicroUSD, &t.WorkEarningsMicroUSD, &t.RewardEarningsMicroUSD, &t.Tokens, &t.Jobs, &t.ActiveAccounts)
	return t
}

// UsageRecords returns usage records from the database, ordered by creation time.
// Limited to the most recent 10000 rows as a safety guard against unbounded reads.
func (s *PostgresStore) UsageRecords() []UsageRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, completion_tokens, created_at, request_id, cost_micro_usd, request_location
			 FROM usage ORDER BY created_at DESC LIMIT 10000`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		var locationRaw []byte
		if err := rows.Scan(
			&r.ProviderID,
			&r.ConsumerKey,
			&r.Model,
			&r.PublicModel,
			&r.PromptTokens,
			&r.CompletionTokens,
			&r.Timestamp,
			&r.RequestID,
			&r.CostMicroUSD,
			&locationRaw,
		); err != nil {
			continue
		}
		r.CreatedAt = r.Timestamp
		r.RequestLocation = unmarshalProviderLocation(locationRaw)
		records = append(records, r)
	}
	if records == nil {
		records = make([]UsageRecord, 0)
	}
	return records
}

// UsageRecordsSince returns usage records created at or after the given time.
func (s *PostgresStore) UsageRecordsSince(since time.Time) []UsageRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, completion_tokens, created_at, request_id, cost_micro_usd, request_location
		 FROM usage
		 WHERE ($1::timestamptz IS NULL OR created_at >= $1)
		 ORDER BY created_at ASC`,
		nullSince(since),
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		var locationRaw []byte
		if err := rows.Scan(
			&r.ProviderID,
			&r.ConsumerKey,
			&r.Model,
			&r.PublicModel,
			&r.PromptTokens,
			&r.CompletionTokens,
			&r.Timestamp,
			&r.RequestID,
			&r.CostMicroUSD,
			&locationRaw,
		); err != nil {
			continue
		}
		r.CreatedAt = r.Timestamp
		r.RequestLocation = unmarshalProviderLocation(locationRaw)
		records = append(records, r)
	}
	if records == nil {
		return []UsageRecord{}
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
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}

	if err := creditTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return err
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit credit: %v: %w", err, ErrCommitOutcomeUnknown)
	}
	return nil
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

// GetBalanceWithWithdrawable returns both balances in a single query.
func (s *PostgresStore) GetBalanceWithWithdrawable(accountID string) (int64, int64) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var balance, withdrawable int64
	err := s.pool.QueryRow(ctx,
		`SELECT balance_micro_usd, withdrawable_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balance, &withdrawable)
	if err != nil {
		return 0, 0
	}
	return balance, withdrawable
}

// CreditWithdrawable adds micro-USD to both the total balance and the
// withdrawable balance, and records a ledger entry.
func (s *PostgresStore) CreditWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}

	if err := creditWithdrawableTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// CreditWithdrawableOnce credits only if no ledger entry with the same
// (entryType, reference) exists yet. A transaction-scoped advisory lock on
// the reference serializes concurrent deliveries of the same webhook so the
// existence check can't race its own insert.
func (s *PostgresStore) CreditWithdrawableOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) (bool, error) {
	if err := s.ensureOwnership(); err != nil {
		return false, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return false, err
	}

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, string(entryType)+":"+reference); err != nil {
		return false, fmt.Errorf("store: advisory lock: %w", err)
	}
	// Scoped by account so the existence check rides the existing
	// idx_ledger_account index instead of needing a new (large-table,
	// boot-time) index migration. Refund references embed the withdrawal
	// UUID, so (account, type, reference) is exactly as unique.
	var exists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM ledger_entries
		  WHERE account_id = $1 AND entry_type = $2 AND reference = $3)`,
		accountID, string(entryType), reference).Scan(&exists); err != nil {
		return false, fmt.Errorf("store: check ledger reference: %w", err)
	}
	if exists {
		return false, tx.Commit(ctx)
	}
	if err := creditWithdrawableTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
func (s *PostgresStore) Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin debit: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}
	var balanceAfter int64
	err = tx.QueryRow(ctx, `
		WITH debit AS (
			UPDATE balances
			SET balance_micro_usd = balance_micro_usd - $2,
			    withdrawable_micro_usd = LEAST(withdrawable_micro_usd, balance_micro_usd - $2),
			    updated_at = NOW()
			WHERE account_id = $1 AND balance_micro_usd >= $2
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
			SELECT $1, $3, -$2, balance_micro_usd, $4
			FROM debit
		)
		SELECT balance_micro_usd FROM debit`,
		accountID, amountMicroUSD, string(entryType), reference,
	).Scan(&balanceAfter)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrInsufficientBalance
		}
		return fmt.Errorf("debit: %w", err)
	}
	return tx.Commit(ctx)
}

// MigrateAccountBalance moves the full balance (and withdrawable subset) from
// one account ID to another in a single transaction. No-op (false) when the
// source has no balance row or a zero balance.
func (s *PostgresStore) MigrateAccountBalance(from, to string) (bool, error) {
	if err := s.ensureOwnership(); err != nil {
		return false, err
	}
	if from == "" || to == "" || from == to {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin migrate tx: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return false, err
	}

	var bal, wdr int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd, withdrawable_micro_usd FROM balances WHERE account_id = $1 FOR UPDATE`, from,
	).Scan(&bal, &wdr)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("store: read source balance: %w", err)
	}
	if bal == 0 && wdr == 0 {
		return false, nil
	}

	// Zero the source and record the outgoing leg.
	if _, err := tx.Exec(ctx,
		`UPDATE balances SET balance_micro_usd = 0, withdrawable_micro_usd = 0, updated_at = NOW() WHERE account_id = $1`, from,
	); err != nil {
		return false, fmt.Errorf("store: zero source balance: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, 0, 'migrate:out')`,
		from, string(LedgerMigration), -bal,
	); err != nil {
		return false, fmt.Errorf("store: source migration ledger entry: %w", err)
	}

	// Credit the destination and record the incoming leg.
	var destBalance int64
	if err := tx.QueryRow(ctx,
		`INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
		 VALUES ($1, $2, $3, NOW())
		 ON CONFLICT (account_id) DO UPDATE SET
		   balance_micro_usd = balances.balance_micro_usd + $2,
		   withdrawable_micro_usd = balances.withdrawable_micro_usd + $3,
		   updated_at = NOW()
		 RETURNING balance_micro_usd`,
		to, bal, wdr,
	).Scan(&destBalance); err != nil {
		return false, fmt.Errorf("store: credit destination balance: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, 'migrate:in')`,
		to, string(LedgerMigration), bal, destBalance,
	); err != nil {
		return false, fmt.Errorf("store: destination migration ledger entry: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("store: commit migrate: %w", err)
	}
	return true, nil
}

// DebitWithdrawable subtracts micro-USD from both the total balance and the
// withdrawable balance atomically. Returns error if the withdrawable balance
// is insufficient. This ensures withdrawal debits are symmetric with
// CreditWithdrawable refunds — both touch the same columns.
func (s *PostgresStore) DebitWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}

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

	currency := strings.ToLower(session.Currency)
	if currency == "" {
		currency = "usd"
	}
	_, err := s.pool.Exec(ctx,
		`INSERT INTO billing_sessions (id, account_id, payment_method, currency, amount_micro_usd, external_id, processed_event_id, status, referral_code)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		session.ID, session.AccountID, session.PaymentMethod,
		currency, session.AmountMicroUSD, session.ExternalID, session.ProcessedEventID,
		session.Status, session.ReferralCode,
	)
	if err != nil {
		return fmt.Errorf("store: create billing session: %w", err)
	}
	return nil
}

func (s *PostgresStore) SetBillingSessionExternalID(sessionID, externalID string) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	if externalID == "" {
		return errors.New("external billing session ID is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx,
		`UPDATE billing_sessions
		 SET external_id = $2
		 WHERE id = $1 AND status = 'pending' AND (external_id = '' OR external_id = $2)`,
		sessionID, externalID,
	)
	if err != nil {
		return fmt.Errorf("store: bind billing session external ID: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("store: billing session %q not pending or already bound", sessionID)
	}
	return nil
}

func (s *PostgresStore) ApplyStripeDeposit(eventID, billingSessionID, checkoutSessionID, currency string, amountMicroUSD int64) (*StripeDepositResult, error) {
	if err := s.ensureOwnership(); err != nil {
		return nil, err
	}
	if eventID == "" || checkoutSessionID == "" {
		return nil, ErrStripeDepositMismatch
	}
	currency = strings.ToLower(currency)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("store: begin Stripe deposit: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return nil, err
	}

	tag, err := tx.Exec(ctx,
		`INSERT INTO stripe_deposit_events
		   (event_id, checkout_session_id, billing_session_id, amount_micro_usd, currency, status)
		 VALUES ($1, $2, $3, $4, $5, 'received')
		 ON CONFLICT DO NOTHING`,
		eventID, checkoutSessionID, billingSessionID, amountMicroUSD, currency,
	)
	if err != nil {
		return nil, fmt.Errorf("store: insert Stripe deposit event: %w", err)
	}
	if tag.RowsAffected() == 0 {
		var existing StripeDepositEvent
		err := tx.QueryRow(ctx,
			`SELECT event_id, checkout_session_id, billing_session_id, amount_micro_usd, currency, status, reason
			 FROM stripe_deposit_events
			 WHERE event_id = $1 OR checkout_session_id = $2
			 ORDER BY (event_id = $1) DESC
			 LIMIT 1
			 FOR UPDATE`,
			eventID, checkoutSessionID,
		).Scan(&existing.EventID, &existing.CheckoutSessionID, &existing.BillingSessionID,
			&existing.AmountMicroUSD, &existing.Currency, &existing.Status, &existing.Reason)
		if err != nil {
			return nil, fmt.Errorf("store: read Stripe deposit replay: %w", err)
		}
		if existing.CheckoutSessionID != checkoutSessionID || existing.BillingSessionID != billingSessionID ||
			existing.AmountMicroUSD != amountMicroUSD || existing.Currency != currency {
			return nil, ErrStripeDepositConflict
		}
		if existing.Status != "applied" && existing.Status != "replayed" {
			if err := tx.Commit(ctx); err != nil {
				return nil, fmt.Errorf("store: commit Stripe rejected replay: %w", err)
			}
			return nil, fmt.Errorf("%w: %s", ErrStripeDepositMismatch, existing.Reason)
		}
		session, err := billingSessionTx(ctx, tx, billingSessionID, false)
		if err != nil {
			return nil, err
		}
		if err := tx.Commit(ctx); err != nil {
			return nil, fmt.Errorf("store: commit Stripe deposit replay: %w", err)
		}
		return &StripeDepositResult{Session: *session, Applied: false}, nil
	}

	session, err := billingSessionTx(ctx, tx, billingSessionID, true)
	if errors.Is(err, pgx.ErrNoRows) {
		return s.rejectStripeDeposit(ctx, tx, eventID, "unknown_billing_session")
	}
	if err != nil {
		return nil, err
	}
	var checkoutConflict bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM billing_sessions
			WHERE external_id = $1 AND id <> $2
		)`,
		checkoutSessionID, billingSessionID,
	).Scan(&checkoutConflict); err != nil {
		return nil, fmt.Errorf("store: check Checkout Session binding: %w", err)
	}
	reason := ""
	switch {
	case session.PaymentMethod != "stripe":
		reason = "payment_method_mismatch"
	case session.Currency != "usd" || currency != session.Currency:
		reason = "currency_mismatch"
	case amountMicroUSD <= 0 || session.AmountMicroUSD != amountMicroUSD:
		reason = "amount_mismatch"
	case session.ExternalID != "" && session.ExternalID != checkoutSessionID:
		reason = "checkout_session_mismatch"
	case checkoutConflict:
		reason = "checkout_session_conflict"
	case session.Status != "pending" && session.Status != "completed":
		reason = "billing_session_not_pending"
	case session.Status == "completed" && session.ExternalID != checkoutSessionID:
		reason = "completed_session_mismatch"
	}
	if reason != "" {
		return s.rejectStripeDeposit(ctx, tx, eventID, reason)
	}
	if session.Status == "completed" {
		if _, err := tx.Exec(ctx,
			`UPDATE stripe_deposit_events
			 SET status = 'replayed', account_id = $2, updated_at = NOW()
			 WHERE event_id = $1`,
			eventID, session.AccountID,
		); err != nil {
			return nil, fmt.Errorf("store: mark Stripe event replayed: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return nil, fmt.Errorf("store: commit Stripe completed replay: %w", err)
		}
		return &StripeDepositResult{Session: *session, Applied: false}, nil
	}

	if session.ReferralCode != "" {
		if _, err := tx.Exec(ctx,
			`INSERT INTO referrals (referred_account, referrer_code)
			 SELECT $1, code FROM referrers
			 WHERE code = $2 AND account_id <> $1
			 ON CONFLICT (referred_account) DO NOTHING`,
			session.AccountID, session.ReferralCode,
		); err != nil {
			return nil, fmt.Errorf("store: apply deposit referral: %w", err)
		}
	}
	tag, err = tx.Exec(ctx,
		`UPDATE billing_sessions
		 SET external_id = $2, processed_event_id = $3, status = 'completed', completed_at = NOW()
		 WHERE id = $1 AND status = 'pending' AND (external_id = '' OR external_id = $2)`,
		billingSessionID, checkoutSessionID, eventID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: complete Stripe billing session: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return s.rejectStripeDeposit(ctx, tx, eventID, "billing_session_changed")
	}
	if err := creditTx(ctx, tx, session.AccountID, amountMicroUSD, LedgerStripeDeposit, "stripe:"+checkoutSessionID, time.Time{}); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE stripe_deposit_events
		 SET status = 'applied', account_id = $2, updated_at = NOW()
		 WHERE event_id = $1`,
		eventID, session.AccountID,
	); err != nil {
		return nil, fmt.Errorf("store: finalize Stripe deposit event: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("store: commit Stripe deposit: %w", err)
	}
	now := time.Now()
	session.ExternalID = checkoutSessionID
	session.ProcessedEventID = eventID
	session.Status = "completed"
	session.CompletedAt = &now
	return &StripeDepositResult{Session: *session, Applied: true}, nil
}

func billingSessionTx(ctx context.Context, tx pgx.Tx, sessionID string, lock bool) (*BillingSession, error) {
	query := `SELECT id, account_id, payment_method, currency, amount_micro_usd, external_id,
	                processed_event_id, status, referral_code, created_at, completed_at
	          FROM billing_sessions WHERE id = $1`
	if lock {
		query += " FOR UPDATE"
	}
	var session BillingSession
	if err := tx.QueryRow(ctx, query, sessionID).Scan(
		&session.ID, &session.AccountID, &session.PaymentMethod, &session.Currency,
		&session.AmountMicroUSD, &session.ExternalID, &session.ProcessedEventID,
		&session.Status, &session.ReferralCode, &session.CreatedAt, &session.CompletedAt,
	); err != nil {
		return nil, err
	}
	return &session, nil
}

func (s *PostgresStore) rejectStripeDeposit(ctx context.Context, tx pgx.Tx, eventID, reason string) (*StripeDepositResult, error) {
	if _, err := tx.Exec(ctx,
		`UPDATE stripe_deposit_events
		 SET status = 'rejected', reason = $2, updated_at = NOW()
		 WHERE event_id = $1`,
		eventID, reason,
	); err != nil {
		return nil, fmt.Errorf("store: reject Stripe deposit event: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("store: commit rejected Stripe deposit: %w", err)
	}
	return nil, fmt.Errorf("%w: %s", ErrStripeDepositMismatch, reason)
}

// GetBillingSession retrieves a billing session by ID.
func (s *PostgresStore) GetBillingSession(sessionID string) (*BillingSession, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var bs BillingSession
	err := s.pool.QueryRow(ctx,
		`SELECT id, account_id, payment_method, currency, amount_micro_usd, external_id, processed_event_id, status, referral_code, created_at, completed_at
		 FROM billing_sessions WHERE id = $1`, sessionID,
	).Scan(&bs.ID, &bs.AccountID, &bs.PaymentMethod, &bs.Currency,
		&bs.AmountMicroUSD, &bs.ExternalID, &bs.ProcessedEventID, &bs.Status, &bs.ReferralCode,
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

	// Invalidate cache.
	key := accountID + ":" + model
	s.priceCacheMu.Lock()
	delete(s.priceCache, key)
	s.priceCacheMu.Unlock()

	return nil
}

func (s *PostgresStore) GetModelPrice(accountID, model string) (int64, int64, bool) {
	key := accountID + ":" + model

	// Check in-memory cache (30-second TTL).
	s.priceCacheMu.RLock()
	if cached, ok := s.priceCache[key]; ok && time.Since(cached.at) < 30*time.Second {
		s.priceCacheMu.RUnlock()
		return cached.input, cached.output, true
	}
	s.priceCacheMu.RUnlock()

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

	// Populate cache.
	s.priceCacheMu.Lock()
	s.priceCache[key] = cachedPrice{input: input, output: output, at: time.Now()}
	s.priceCacheMu.Unlock()

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
		`INSERT INTO users (account_id, privy_user_id, email, role, platform_fee_percent)
		 VALUES ($1, $2, $3, $4, $5)`,
		user.AccountID, user.PrivyUserID, user.Email, user.Role, user.PlatformFeePercent,
	)
	if err != nil {
		return fmt.Errorf("store: create user: %w", err)
	}
	return nil
}

const userSelectColumns = `account_id, privy_user_id, email, role, platform_fee_percent,
	stripe_account_id, stripe_account_status, stripe_account_country,
	stripe_destination_type, stripe_destination_last4, stripe_instant_eligible, created_at`

func scanUser(row interface {
	Scan(...any) error
}) (*User, error) {
	var u User
	if err := row.Scan(&u.AccountID, &u.PrivyUserID, &u.Email, &u.Role, &u.PlatformFeePercent,
		&u.StripeAccountID, &u.StripeAccountStatus, &u.StripeAccountCountry,
		&u.StripeDestinationType, &u.StripeDestinationLast4, &u.StripeInstantEligible, &u.CreatedAt); err != nil {
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
// stripeAccountCountry is the ISO country the Express account is locked to.
// Pass an empty string to leave the existing country value unchanged.
func (s *PostgresStore) SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4 string, instantEligible bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	countryClause := ""
	args := []any{accountID, stripeAccountID, status, destinationType, destinationLast4, instantEligible}
	switch {
	case stripeAccountCountry != "":
		countryClause = ", stripe_account_country = $7"
		args = append(args, stripeAccountCountry)
	case stripeAccountID == "":
		// Unlinking: empty country normally means "keep existing", but with
		// no account there is no country — a stale value would leak into the
		// next onboarding attempt.
		countryClause = ", stripe_account_country = ''"
	}

	tag, err := s.pool.Exec(ctx,
		fmt.Sprintf(`UPDATE users SET
			stripe_account_id = $2,
			stripe_account_status = $3,
			stripe_destination_type = $4,
			stripe_destination_last4 = $5,
			stripe_instant_eligible = $6%s
		 WHERE account_id = $1`, countryClause),
		args...,
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

// SetUserRole sets the account role on a user record.
func (s *PostgresStore) SetUserRole(accountID, role string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE users SET role = $2 WHERE account_id = $1`,
		accountID, role,
	)
	if err != nil {
		return fmt.Errorf("store: set user role: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	return nil
}

// SetUserPlatformFeePercent sets (or clears, when nil) the per-account platform
// fee override.
func (s *PostgresStore) SetUserPlatformFeePercent(accountID string, feePercent *int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE users SET platform_fee_percent = $2 WHERE account_id = $1`,
		accountID, feePercent,
	)
	if err != nil {
		return fmt.Errorf("store: set user platform fee: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	return nil
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
	if err := s.ensureOwnership(); err != nil {
		return err
	}
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
		 (id, account_id, stripe_account_id, transfer_id, payout_id, sweep_payout_id,
		  amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
		  failure_reason, refunded, fee_refunded, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)`,
		w.ID, w.AccountID, w.StripeAccountID, w.TransferID, w.PayoutID, w.SweepPayoutID,
		w.AmountMicroUSD, w.FeeMicroUSD, w.NetMicroUSD, w.Method, w.Status,
		w.FailureReason, w.Refunded, w.FeeRefunded, w.CreatedAt, w.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("store: create stripe withdrawal: %w", err)
	}
	return nil
}

// CreateStripeWithdrawalWithDebit atomically debits both balance columns
// (recording the ledger entry) and inserts the withdrawal row in a single
// transaction — a crash can no longer leave a debited balance with no
// withdrawal row. Returns ErrInsufficientBalance when the guarded debit
// matches no row.
func (s *PostgresStore) CreateStripeWithdrawalWithDebit(w *StripeWithdrawal, entryType LedgerEntryType, reference string) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	if w.AmountMicroUSD <= 0 {
		return errors.New("stripe withdrawal amount must be positive")
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

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}

	// Same guarded dual-column debit as DebitWithdrawable: both the total
	// and withdrawable balances must cover the amount.
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
		w.AccountID, w.AmountMicroUSD,
	).Scan(&balanceAfter)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("store: insufficient withdrawable balance: %w", ErrInsufficientBalance)
		}
		return fmt.Errorf("store: withdrawal debit: %w", err)
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, $5)`,
		w.AccountID, string(entryType), -w.AmountMicroUSD, balanceAfter, reference,
	); err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO stripe_withdrawals
		 (id, account_id, stripe_account_id, transfer_id, payout_id, sweep_payout_id,
		  amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
		  failure_reason, refunded, fee_refunded, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)`,
		w.ID, w.AccountID, w.StripeAccountID, w.TransferID, w.PayoutID, w.SweepPayoutID,
		w.AmountMicroUSD, w.FeeMicroUSD, w.NetMicroUSD, w.Method, w.Status,
		w.FailureReason, w.Refunded, w.FeeRefunded, w.CreatedAt, w.UpdatedAt,
	); err != nil {
		return fmt.Errorf("store: create stripe withdrawal: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit stripe withdrawal debit: %v: %w", err, ErrCommitOutcomeUnknown)
	}
	return nil
}

const stripeWithdrawalSelectColumns = `id, account_id, stripe_account_id, transfer_id, payout_id, sweep_payout_id,
	amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
	failure_reason, refunded, fee_refunded, created_at, updated_at`

func scanStripeWithdrawal(row interface{ Scan(...any) error }) (*StripeWithdrawal, error) {
	var w StripeWithdrawal
	if err := row.Scan(&w.ID, &w.AccountID, &w.StripeAccountID, &w.TransferID, &w.PayoutID, &w.SweepPayoutID,
		&w.AmountMicroUSD, &w.FeeMicroUSD, &w.NetMicroUSD, &w.Method, &w.Status,
		&w.FailureReason, &w.Refunded, &w.FeeRefunded, &w.CreatedAt, &w.UpdatedAt); err != nil {
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
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("store: stripe withdrawal with payout %q: %w", payoutID, ErrNotFound)
		}
		return nil, fmt.Errorf("store: get stripe withdrawal by payout %q: %w", payoutID, err)
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
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("store: stripe withdrawal with transfer %q: %w", transferID, ErrNotFound)
		}
		return nil, fmt.Errorf("store: get stripe withdrawal by transfer %q: %w", transferID, err)
	}
	return w, nil
}

func (s *PostgresStore) UpdateStripeWithdrawal(w *StripeWithdrawal) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin stripe withdrawal update: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx,
		`UPDATE stripe_withdrawals SET
			transfer_id = $2, payout_id = $3, sweep_payout_id = $4, status = $5,
			failure_reason = $6, refunded = $7, fee_refunded = $8, updated_at = NOW()
		 WHERE id = $1`,
		w.ID, w.TransferID, w.PayoutID, w.SweepPayoutID, w.Status, w.FailureReason, w.Refunded, w.FeeRefunded,
	)
	if err != nil {
		return fmt.Errorf("store: update stripe withdrawal: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("stripe withdrawal %q not found", w.ID)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit stripe withdrawal update: %w", err)
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

// MarkStripeWithdrawalPaid atomically flips a non-terminal, non-refunded
// withdrawal to "paid" with an in-database guard (see interface doc).
func (s *PostgresStore) MarkStripeWithdrawalPaid(id, expectedPayoutID, sweepPayoutID string) (bool, error) {
	if err := s.ensureOwnership(); err != nil {
		return false, err
	}
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin mark stripe withdrawal paid: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return false, err
	}
	if sweepPayoutID != "" {
		if _, err := tx.Exec(ctx,
			`SELECT pg_advisory_xact_lock(hashtext($1))`,
			"stripe-sweep:"+sweepPayoutID,
		); err != nil {
			return false, fmt.Errorf("store: lock stripe sweep payout: %w", err)
		}
		var failed bool
		if err := tx.QueryRow(ctx,
			`SELECT EXISTS (
				SELECT 1 FROM stripe_sweep_failures WHERE payout_id = $1
			)`,
			sweepPayoutID,
		).Scan(&failed); err != nil {
			return false, fmt.Errorf("store: check stripe sweep failure: %w", err)
		}
		if failed {
			if err := tx.Commit(ctx); err != nil {
				return false, fmt.Errorf("store: commit rejected paid sweep: %w", err)
			}
			return false, nil
		}
	}
	tag, err := tx.Exec(ctx,
		`UPDATE stripe_withdrawals
		 SET status = 'paid',
		     sweep_payout_id = CASE WHEN $3 <> '' THEN $3 ELSE sweep_payout_id END,
		     updated_at = NOW()
		 WHERE id = $1
		   AND refunded = FALSE
		   AND status IN ('pending', 'transferred')
		   AND payout_id = $2`,
		id, expectedPayoutID, sweepPayoutID,
	)
	if err != nil {
		return false, fmt.Errorf("store: mark stripe withdrawal paid: %w", err)
	}
	applied := tag.RowsAffected() > 0
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("store: commit mark stripe withdrawal paid: %w", err)
	}
	return applied, nil
}

func (s *PostgresStore) RecordStripeSweepFailure(
	sweepPayoutID, failureReason string,
) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	if sweepPayoutID == "" {
		return errors.New("sweep payout ID is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin stripe sweep failure: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		`SELECT pg_advisory_xact_lock(hashtext($1))`,
		"stripe-sweep:"+sweepPayoutID,
	); err != nil {
		return fmt.Errorf("store: lock failed stripe sweep: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO stripe_sweep_failures (payout_id, failure_reason)
		 VALUES ($1, $2)
		 ON CONFLICT (payout_id) DO UPDATE SET failure_reason = EXCLUDED.failure_reason`,
		sweepPayoutID, failureReason,
	); err != nil {
		return fmt.Errorf("store: record stripe sweep failure: %w", err)
	}
	return tx.Commit(ctx)
}

func (s *PostgresStore) RefundStripeWithdrawalOnReversal(id string) (bool, bool, error) {
	if err := s.ensureOwnership(); err != nil {
		return false, false, err
	}
	if id == "" {
		return false, false, errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, false, fmt.Errorf("store: begin transfer reversal refund: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return false, false, err
	}
	withdrawal, err := scanStripeWithdrawal(tx.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+`
		 FROM stripe_withdrawals WHERE id = $1 FOR UPDATE`,
		id,
	))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, false, fmt.Errorf("stripe withdrawal %q: %w", id, ErrNotFound)
		}
		return false, false, fmt.Errorf("store: lock reversed withdrawal: %w", err)
	}
	if withdrawal.Status == "paid" || withdrawal.Status == "review_pending" {
		if withdrawal.Status == "paid" {
			if _, err := tx.Exec(ctx,
				`UPDATE stripe_withdrawals
				 SET status = 'review_pending',
				     failure_reason = 'transfer_reversed_after_paid',
				     updated_at = NOW()
				 WHERE id = $1`,
				id,
			); err != nil {
				return false, false, fmt.Errorf("store: persist paid reversal review: %w", err)
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return false, false, fmt.Errorf("store: commit paid reversal review: %w", err)
		}
		return false, true, nil
	}
	if withdrawal.Refunded {
		if _, err := tx.Exec(ctx,
			`UPDATE stripe_withdrawals
			 SET status = 'failed', failure_reason = 'transfer_reversed', updated_at = NOW()
			 WHERE id = $1`,
			id,
		); err != nil {
			return false, false, fmt.Errorf("store: terminalize refunded reversal: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return false, false, fmt.Errorf("store: commit refunded reversal: %w", err)
		}
		return false, false, nil
	}
	net := withdrawal.AmountMicroUSD - withdrawal.FeeMicroUSD
	if net > 0 {
		if _, err := creditWithdrawableReferenceTx(
			ctx, tx, withdrawal.AccountID, net, "stripe_withdraw:"+withdrawal.ID,
		); err != nil {
			return false, false, err
		}
	}
	feeRefunded := withdrawal.FeeRefunded
	if withdrawal.FeeMicroUSD > 0 && !feeRefunded {
		_, err := creditWithdrawableReferenceTx(
			ctx, tx, withdrawal.AccountID, withdrawal.FeeMicroUSD,
			"stripe_withdraw_fee:"+withdrawal.ID,
		)
		if err != nil {
			return false, false, err
		}
		feeRefunded = true
	}
	if _, err := tx.Exec(ctx,
		`UPDATE stripe_withdrawals
		 SET refunded = TRUE, fee_refunded = (fee_refunded OR $2),
		     status = 'failed', failure_reason = 'transfer_reversed', updated_at = NOW()
		 WHERE id = $1`,
		id, feeRefunded,
	); err != nil {
		return false, false, fmt.Errorf("store: finalize reversed withdrawal: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return false, false, fmt.Errorf("store: commit reversed withdrawal: %w", err)
	}
	return true, false, nil
}

func creditWithdrawableReferenceTx(
	ctx context.Context,
	tx pgx.Tx,
	accountID string,
	amount int64,
	reference string,
) (bool, error) {
	if _, err := tx.Exec(ctx,
		`SELECT pg_advisory_xact_lock(hashtext($1))`,
		string(LedgerRefund)+":"+reference,
	); err != nil {
		return false, fmt.Errorf("store: lock reversal refund reference: %w", err)
	}
	var exists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM ledger_entries
			WHERE account_id = $1 AND entry_type = $2 AND reference = $3
		)`,
		accountID, string(LedgerRefund), reference,
	).Scan(&exists); err != nil {
		return false, fmt.Errorf("store: check reversal refund reference: %w", err)
	}
	if exists {
		return false, nil
	}
	if err := creditWithdrawableTx(
		ctx, tx, accountID, amount, LedgerRefund, reference, time.Time{},
	); err != nil {
		return false, err
	}
	return true, nil
}

// ReopenStripeWithdrawalAfterPayoutFailure atomically reopens a bounced
// withdrawal for sweep retry with an in-database guard (see interface doc).
func (s *PostgresStore) ReopenStripeWithdrawalAfterPayoutFailure(id, failureReason string, feeRefunded bool) (bool, error) {
	if err := s.ensureOwnership(); err != nil {
		return false, err
	}
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin reopen stripe withdrawal: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return false, err
	}
	tag, err := tx.Exec(ctx,
		`UPDATE stripe_withdrawals
		 SET status = 'transferred',
		     payout_id = '',
		     failure_reason = $2,
		     fee_refunded = (fee_refunded OR $3),
		     updated_at = NOW()
		 WHERE id = $1
		   AND refunded = FALSE
		   AND status NOT IN ('failed', 'review_pending')`,
		id, failureReason, feeRefunded,
	)
	if err != nil {
		return false, fmt.Errorf("store: reopen stripe withdrawal: %w", err)
	}
	applied := tag.RowsAffected() > 0
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("store: commit reopen stripe withdrawal: %w", err)
	}
	return applied, nil
}

func (s *PostgresStore) ReopenStripeWithdrawalAfterSweepFailure(
	id, sweepPayoutID, failureReason string,
) (bool, error) {
	if err := s.ensureOwnership(); err != nil {
		return false, err
	}
	if id == "" || sweepPayoutID == "" {
		return false, errors.New("stripe withdrawal and sweep payout IDs are required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin reopen sweep withdrawal: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return false, err
	}
	tag, err := tx.Exec(ctx,
		`UPDATE stripe_withdrawals
		 SET status = 'transferred', sweep_payout_id = '',
		     failure_reason = $3, updated_at = NOW()
		 WHERE id = $1
		   AND sweep_payout_id = $2
		   AND status = 'paid'
		   AND refunded = FALSE`,
		id, sweepPayoutID, failureReason,
	)
	if err != nil {
		return false, fmt.Errorf("store: reopen sweep withdrawal: %w", err)
	}
	applied := tag.RowsAffected() > 0
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("store: commit reopen sweep withdrawal: %w", err)
	}
	return applied, nil
}

// ListStripeWithdrawalsBySweepPayoutID returns the rows stamped by the given
// automatic sweep payout, oldest first.
func (s *PostgresStore) ListStripeWithdrawalsBySweepPayoutID(sweepPayoutID string) ([]StripeWithdrawal, error) {
	if sweepPayoutID == "" {
		return []StripeWithdrawal{}, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals
		 WHERE sweep_payout_id = $1 ORDER BY created_at ASC`,
		sweepPayoutID)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals by sweep payout: %w", err)
	}
	defer rows.Close()

	out := []StripeWithdrawal{}
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	return out, nil
}

// ListStripeWithdrawalsByStatus returns up to limit withdrawals in the given
// status created before olderThan, oldest first. Limits <= 0 or above the cap
// are clamped to MaxStripeWithdrawalsByStatusLimit — never unbounded.
func (s *PostgresStore) ListStripeWithdrawalsByStatus(status string, olderThan time.Time, limit int) ([]StripeWithdrawal, error) {
	if limit <= 0 || limit > MaxStripeWithdrawalsByStatusLimit {
		limit = MaxStripeWithdrawalsByStatusLimit
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	q := `SELECT ` + stripeWithdrawalSelectColumns + ` FROM stripe_withdrawals
		 WHERE status = $1 AND created_at < $2 ORDER BY created_at ASC LIMIT $3`
	args := []any{status, olderThan, limit}
	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals by status: %w", err)
	}
	defer rows.Close()

	out := []StripeWithdrawal{}
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	return out, nil
}

// ListStripeWithdrawalsForStripeAccount returns withdrawals destined for the
// given connected account in the given status, oldest first. Capped at
// MaxStripeWithdrawalsByStatusLimit as a webhook-path safety bound (a single
// account should never approach it; stragglers are picked up on redelivery
// or the next sweep since completed rows drop out of the status filter).
func (s *PostgresStore) ListStripeWithdrawalsForStripeAccount(stripeAccountID, status string) ([]StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals
		 WHERE stripe_account_id = $1 AND status = $2 ORDER BY created_at ASC LIMIT $3`,
		stripeAccountID, status, MaxStripeWithdrawalsByStatusLimit)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals for stripe account: %w", err)
	}
	defer rows.Close()

	out := []StripeWithdrawal{}
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	return out, nil
}

// --- Releases ---

func (s *PostgresStore) SetRelease(release *Release) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO releases (version, platform, backend, binary_hash, bundle_hash, metallib_hash, python_hash, runtime_hash, template_hashes, url, changelog, active, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, TRUE, NOW())
		 ON CONFLICT (version, platform) DO UPDATE SET
		   backend = $3, binary_hash = $4, bundle_hash = $5, metallib_hash = $6, python_hash = $7, runtime_hash = $8, template_hashes = $9, url = $10, changelog = $11, active = TRUE`,
		release.Version, release.Platform, release.Backend, release.BinaryHash, release.BundleHash,
		release.MetallibHash, release.PythonHash, release.RuntimeHash, release.TemplateHashes,
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
		`SELECT version, platform, COALESCE(backend, ''), binary_hash, bundle_hash, COALESCE(metallib_hash, ''),
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
		if err := rows.Scan(&r.Version, &r.Platform, &r.Backend, &r.BinaryHash, &r.BundleHash, &r.MetallibHash,
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
		`SELECT version, platform, COALESCE(backend, ''), binary_hash, bundle_hash, COALESCE(metallib_hash, ''),
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
		if err := rows.Scan(&r.Version, &r.Platform, &r.Backend, &r.BinaryHash, &r.BundleHash, &r.MetallibHash,
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
	createdAt := earning.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now()
	}

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		 ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING`,
		earning.AccountID, earning.ProviderID, earning.ProviderKey, earning.JobID,
		earning.Model, earning.AmountMicroUSD, earning.PromptTokens, earning.CompletionTokens,
		createdAt,
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
// Reads from the materialized earnings_summary table (PK lookup) instead of
// scanning all provider_earnings rows.
func (s *PostgresStore) GetProviderEarningsSummary(providerKey string) (ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary ProviderEarningsSummary
	err := s.pool.QueryRow(ctx,
		`SELECT total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens
		 FROM earnings_summary
		 WHERE key = $1 AND key_type = 'provider'`,
		providerKey,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens)
	if err != nil {
		// No rows = no earnings yet, return zeros (not an error).
		return ProviderEarningsSummary{}, nil
	}

	return summary, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
// Reads from the materialized earnings_summary table (PK lookup) instead of
// scanning all provider_earnings rows.
func (s *PostgresStore) GetAccountEarningsSummary(accountID string) (ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary ProviderEarningsSummary
	err := s.pool.QueryRow(ctx,
		`SELECT total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens
		 FROM earnings_summary
		 WHERE key = $1 AND key_type = 'account'`,
		accountID,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens)
	if err != nil {
		// No rows = no earnings yet, return zeros (not an error).
		return ProviderEarningsSummary{}, nil
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
	if err := s.ensureOwnership(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin settle provider payout: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx,
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
	return tx.Commit(ctx)
}

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning.
//
// Single-statement CTE: upsert balance, insert ledger entry, insert earning --
// all in one round trip. The old implementation used 6 sequential round trips
// (BEGIN + upsert + SELECT balance + INSERT ledger + INSERT earning + COMMIT).
func (s *PostgresStore) CreditProviderAccount(earning *ProviderEarning) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
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
		return fmt.Errorf("store: begin provider account credit: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}

	// The earning CTE is the idempotency gate: ON CONFLICT (job_id) DO NOTHING
	// means a retried settlement (same job_id) inserts nothing and RETURNS no
	// row, so every downstream CTE (which selects FROM earning) is a pure no-op
	// — no balance bump, no ledger row, no summary bump. The outer COALESCE keeps
	// the query returning exactly one row even on a duplicate.
	var balanceAfter int64
	err = tx.QueryRow(ctx, `
		WITH earning AS (
			INSERT INTO provider_earnings (
				account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
			) VALUES ($1, $6, $7, $4, $8, $2, $9, $10, COALESCE($5::timestamptz, NOW()))
			ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING
			RETURNING account_id, provider_key, amount_micro_usd, prompt_tokens, completion_tokens
		), credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			SELECT account_id, amount_micro_usd, amount_micro_usd, NOW() FROM earning
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
			  withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT e.account_id, $3, e.amount_micro_usd, c.balance_micro_usd, $4, COALESCE($5::timestamptz, NOW())
			FROM earning e CROSS JOIN credit c
		), summary_account AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT account_id, 'account', 1, amount_micro_usd, prompt_tokens, completion_tokens, NOW() FROM earning
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + 1,
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
			  total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
			  updated_at = NOW()
		), summary_provider AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT provider_key, 'provider', 1, amount_micro_usd, prompt_tokens, completion_tokens, NOW() FROM earning
			WHERE provider_key <> ''
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + 1,
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
			  total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
			  updated_at = NOW()
		)
		SELECT COALESCE((SELECT balance_micro_usd FROM credit), 0)`,
		earning.AccountID,                    // $1
		earning.AmountMicroUSD,               // $2
		string(LedgerPayout),                 // $3
		earning.JobID,                        // $4
		nullableCreatedAt(earning.CreatedAt), // $5
		earning.ProviderID,                   // $6
		earning.ProviderKey,                  // $7
		earning.Model,                        // $8
		earning.PromptTokens,                 // $9
		earning.CompletionTokens,             // $10
	).Scan(&balanceAfter)
	if err != nil {
		return fmt.Errorf("store: credit provider account: %w", err)
	}
	return tx.Commit(ctx)
}

// CreditProviderWallet atomically credits an unlinked provider wallet and
// records the corresponding payout history row.
func (s *PostgresStore) CreditProviderWallet(payout *ProviderPayout) error {
	if err := s.ensureOwnership(); err != nil {
		return err
	}
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
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}

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

func marshalProviderLocation(loc *ProviderLocation) json.RawMessage {
	if loc == nil {
		return nil
	}
	b, err := json.Marshal(loc)
	if err != nil {
		return nil
	}
	return b
}

func unmarshalProviderLocation(raw []byte) *ProviderLocation {
	if len(raw) == 0 {
		return nil
	}
	var loc ProviderLocation
	if err := json.Unmarshal(raw, &loc); err != nil {
		return nil
	}
	return &loc
}

func providerStatsJSON(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return json.RawMessage(`{}`)
	}
	return raw
}

func (s *PostgresStore) UpsertProvider(ctx context.Context, p ProviderRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO providers (
			id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7,
			$8, $9, $10,
			$11, $12,
			$13, $14, $15, $16,
			$17, $18, $19,
			$20, $21, $22, $23,
			$24, $25,
			$26, $27, $28
		)
		ON CONFLICT (id) DO UPDATE SET
			hardware = $2, models = $3, backend = $4, location = $5,
			trust_level = $6, attested = $7,
			attestation_result = $8, se_public_key = $9, serial_number = $10,
			mda_verified = $11, mda_cert_chain = $12,
			version = $13, runtime_verified = $14, python_hash = $15, runtime_hash = $16,
			last_challenge_verified = $17, failed_challenges = $18, account_id = $19,
			lifetime_requests_served = $20, lifetime_tokens_generated = $21,
			last_session_requests_served = $22, last_session_tokens_generated = $23,
			lifetime_stats = $24, last_session_stats = $25,
			last_seen = $27, public_key = $28`,
		p.ID, p.Hardware, p.Models, p.Backend,
		marshalProviderLocation(p.Location),
		p.TrustLevel, p.Attested,
		p.AttestationResult, p.SEPublicKey, p.SerialNumber,
		p.MDAVerified, p.MDACertChain,
		p.Version, p.RuntimeVerified, p.PythonHash, p.RuntimeHash,
		p.LastChallengeVerified, p.FailedChallenges, p.AccountID,
		p.LifetimeRequestsServed, p.LifetimeTokensGenerated,
		p.LastSessionRequestsServed, p.LastSessionTokensGenerated,
		providerStatsJSON(p.LifetimeStats), providerStatsJSON(p.LastSessionStats),
		p.RegisteredAt, p.LastSeen, p.PublicKey,
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
	var locationRaw []byte
	err := s.pool.QueryRow(ctx,
		`SELECT id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key
		 FROM providers WHERE id = $1`, id,
	).Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&locationRaw,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
		&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
		&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
		&p.LifetimeStats, &p.LastSessionStats,
		&p.RegisteredAt, &p.LastSeen, &p.PublicKey,
	)
	if err != nil {
		return nil, fmt.Errorf("store: provider not found: %w", err)
	}
	p.Location = unmarshalProviderLocation(locationRaw)
	return &p, nil
}

func (s *PostgresStore) GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var p ProviderRecord
	var locationRaw []byte
	err := s.pool.QueryRow(ctx,
		`SELECT id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key
		 FROM providers WHERE serial_number = $1 AND serial_number != ''
		 ORDER BY last_seen DESC LIMIT 1`, serial,
	).Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&locationRaw,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
		&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
		&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
		&p.LifetimeStats, &p.LastSessionStats,
		&p.RegisteredAt, &p.LastSeen, &p.PublicKey,
	)
	if err != nil {
		return nil, fmt.Errorf("store: provider with serial not found: %w", err)
	}
	p.Location = unmarshalProviderLocation(locationRaw)
	return &p, nil
}

func (s *PostgresStore) GetMDAChainBySerial(ctx context.Context, serial string) (json.RawMessage, error) {
	if serial == "" {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	// Newest NON-EMPTY chain for the serial — skips a reconnect's empty row that
	// would otherwise shadow a still-valid chain from a prior connection.
	var chain json.RawMessage
	err := s.pool.QueryRow(ctx,
		`SELECT mda_cert_chain FROM providers
		 WHERE serial_number = $1 AND serial_number != '' AND mda_cert_chain IS NOT NULL
		 ORDER BY last_seen DESC LIMIT 1`, serial,
	).Scan(&chain)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("store: get mda chain by serial: %w", err)
	}
	return chain, nil
}

func (s *PostgresStore) ListProviderRecords(ctx context.Context) ([]ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key
		 FROM providers ORDER BY last_seen DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list providers: %w", err)
	}
	defer rows.Close()

	var records []ProviderRecord
	for rows.Next() {
		var p ProviderRecord
		var locationRaw []byte
		if err := rows.Scan(
			&p.ID, &p.Hardware, &p.Models, &p.Backend,
			&locationRaw,
			&p.TrustLevel, &p.Attested,
			&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
			&p.MDAVerified, &p.MDACertChain,
			&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
			&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
			&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
			&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
			&p.LifetimeStats, &p.LastSessionStats,
			&p.RegisteredAt, &p.LastSeen, &p.PublicKey,
		); err != nil {
			continue
		}
		p.Location = unmarshalProviderLocation(locationRaw)
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
		 id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key
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
		var locationRaw []byte
		if err := rows.Scan(
			&p.ID, &p.Hardware, &p.Models, &p.Backend,
			&locationRaw,
			&p.TrustLevel, &p.Attested,
			&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
			&p.MDAVerified, &p.MDACertChain,
			&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
			&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
			&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
			&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
			&p.LifetimeStats, &p.LastSessionStats,
			&p.RegisteredAt, &p.LastSeen, &p.PublicKey,
		); err != nil {
			continue
		}
		p.Location = unmarshalProviderLocation(locationRaw)
		records = append(records, p)
	}
	return records, nil
}

func (s *PostgresStore) DeleteProvidersBySerial(ctx context.Context, ownerAccountID, serialOrID string) (int, error) {
	if ownerAccountID == "" || serialOrID == "" {
		return 0, nil
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("store: delete providers begin: %w", err)
	}
	defer tx.Rollback(ctx)

	// Resolve all provider rows for this owner matching the stable identity
	// (serial OR session id). Postgres keeps one row per session UUID, so a
	// serial can map to many ids — delete them all.
	rows, err := tx.Query(ctx,
		`SELECT id FROM providers
		 WHERE account_id = $1
		   AND ((serial_number = $2 AND serial_number <> '') OR id = $2)`,
		ownerAccountID, serialOrID,
	)
	if err != nil {
		return 0, fmt.Errorf("store: delete providers select: %w", err)
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, fmt.Errorf("store: delete providers scan: %w", err)
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("store: delete providers iterate: %w", err)
	}
	if len(ids) == 0 {
		if err := tx.Commit(ctx); err != nil {
			return 0, fmt.Errorf("store: delete providers commit: %w", err)
		}
		return 0, nil
	}

	// provider_reputation.provider_id has a FK to providers(id) with NO
	// ON DELETE CASCADE — delete the reputation rows FIRST or the providers
	// delete fails. usage / provider_earnings / provider_sessions hold
	// money/uptime history and have no FK; they are intentionally preserved.
	if _, err := tx.Exec(ctx,
		`DELETE FROM provider_reputation WHERE provider_id = ANY($1)`, ids,
	); err != nil {
		return 0, fmt.Errorf("store: delete provider reputation: %w", err)
	}

	tag, err := tx.Exec(ctx,
		`DELETE FROM providers WHERE id = ANY($1) AND account_id = $2`,
		ids, ownerAccountID,
	)
	if err != nil {
		return 0, fmt.Errorf("store: delete providers: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("store: delete providers commit: %w", err)
	}
	return int(tag.RowsAffected()), nil
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

// --- APNs code-identity attestation reuse cache (W5 Fix 2) ---

func (s *PostgresStore) ListCodeAttestations(ctx context.Context) ([]CodeAttestation, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, version, attested_at, apns_token FROM code_attestations`)
	if err != nil {
		return nil, fmt.Errorf("store: list code attestations: %w", err)
	}
	defer rows.Close()

	var out []CodeAttestation
	for rows.Next() {
		var rec CodeAttestation
		if err := rows.Scan(&rec.SEPubKey, &rec.Version, &rec.AttestedAt, &rec.APNsToken); err != nil {
			return nil, fmt.Errorf("store: scan code attestation: %w", err)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate code attestations: %w", err)
	}
	return out, nil
}

func (s *PostgresStore) UpsertCodeAttestation(ctx context.Context, rec CodeAttestation) error {
	if rec.SEPubKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO code_attestations (se_pubkey, version, attested_at, apns_token)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (se_pubkey) DO UPDATE SET
			version = $2, attested_at = $3, apns_token = $4`,
		rec.SEPubKey, rec.Version, rec.AttestedAt, rec.APNsToken,
	)
	if err != nil {
		return fmt.Errorf("store: upsert code attestation: %w", err)
	}
	return nil
}

func (s *PostgresStore) DeleteCodeAttestation(ctx context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	if _, err := s.pool.Exec(ctx, `DELETE FROM code_attestations WHERE se_pubkey = $1`, seKey); err != nil {
		return fmt.Errorf("store: delete code attestation: %w", err)
	}
	return nil
}

// --- Provider trust-reuse cache (DAR-326 Phase 0) ---

func (s *PostgresStore) ListProviderTrustReuse(ctx context.Context) ([]ProviderTrustReuse, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, serial, trust_level, binary_hash, sip_enabled, secure_boot_full, mda_udid, verified_at FROM provider_trust_reuse`)
	if err != nil {
		return nil, fmt.Errorf("store: list provider trust reuse: %w", err)
	}
	defer rows.Close()

	var out []ProviderTrustReuse
	for rows.Next() {
		var rec ProviderTrustReuse
		if err := rows.Scan(&rec.SEPubKey, &rec.Serial, &rec.TrustLevel, &rec.BinaryHash, &rec.SIPEnabled, &rec.SecureBootFull, &rec.MDAUDID, &rec.VerifiedAt); err != nil {
			return nil, fmt.Errorf("store: scan provider trust reuse: %w", err)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate provider trust reuse: %w", err)
	}
	return out, nil
}

func (s *PostgresStore) UpsertProviderTrustReuse(ctx context.Context, rec ProviderTrustReuse) error {
	if rec.SEPubKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_trust_reuse (se_pubkey, serial, trust_level, binary_hash, sip_enabled, secure_boot_full, mda_udid, verified_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		 ON CONFLICT (se_pubkey) DO UPDATE SET
			serial = $2, trust_level = $3, binary_hash = $4, sip_enabled = $5, secure_boot_full = $6, mda_udid = $7, verified_at = $8`,
		rec.SEPubKey, rec.Serial, rec.TrustLevel, rec.BinaryHash, rec.SIPEnabled, rec.SecureBootFull, rec.MDAUDID, rec.VerifiedAt,
	)
	if err != nil {
		return fmt.Errorf("store: upsert provider trust reuse: %w", err)
	}
	return nil
}

func (s *PostgresStore) DeleteProviderTrustReuse(ctx context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	if _, err := s.pool.Exec(ctx, `DELETE FROM provider_trust_reuse WHERE se_pubkey = $1`, seKey); err != nil {
		return fmt.Errorf("store: delete provider trust reuse: %w", err)
	}
	return nil
}

// --- Provider Log Reports ---

const maxLogReportSize = 10 << 20 // 10 MB

func (s *PostgresStore) StoreLogReport(serialNumber, providerID, accountID string, logData []byte) error {
	if len(logData) > maxLogReportSize {
		logData = logData[:maxLogReportSize]
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_log_reports (serial_number, provider_id, account_id, log_data, log_size_bytes)
		 VALUES ($1, $2, $3, $4, $5)`,
		serialNumber, providerID, accountID, logData, int64(len(logData)),
	)
	if err != nil {
		return fmt.Errorf("store: insert log report: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetLogReports(serialNumber string, limit int) ([]LogReport, error) {
	if limit <= 0 || limit > 100 {
		limit = 10
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, serial_number, provider_id, account_id, log_size_bytes, created_at
		 FROM provider_log_reports
		 WHERE serial_number = $1
		 ORDER BY created_at DESC
		 LIMIT $2`,
		serialNumber, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list log reports: %w", err)
	}
	defer rows.Close()

	var reports []LogReport
	for rows.Next() {
		var r LogReport
		if err := rows.Scan(&r.ID, &r.SerialNumber, &r.ProviderID, &r.AccountID, &r.LogSizeBytes, &r.CreatedAt); err != nil {
			continue
		}
		reports = append(reports, r)
	}
	if reports == nil {
		return []LogReport{}, nil
	}
	return reports, nil
}

func (s *PostgresStore) GetLogReport(id int64) (*LogReport, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var r LogReport
	err := s.pool.QueryRow(ctx,
		`SELECT id, serial_number, provider_id, account_id, log_data, log_size_bytes, created_at
		 FROM provider_log_reports WHERE id = $1`, id,
	).Scan(&r.ID, &r.SerialNumber, &r.ProviderID, &r.AccountID, &r.LogData, &r.LogSizeBytes, &r.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: log report %d not found: %w", id, err)
	}
	return &r, nil
}

// OpenProviderSession records the start of a provider connection. Idempotent:
// ON CONFLICT DO NOTHING so a duplicate register, or an open that races behind a
// close (fast connect→disconnect), never creates a second or reopened row.
func (s *PostgresStore) OpenProviderSession(ctx context.Context, sessionID, serial, accountID string) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_sessions (session_id, serial_number, account_id)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (session_id) DO NOTHING`,
		sessionID, serial, accountID,
	)
	if err != nil {
		return fmt.Errorf("store: open provider session: %w", err)
	}
	return nil
}

// TouchProviderSession updates the open session's last_seen and backfills
// serial/account/provider_key if they were unknown at open time.
func (s *PostgresStore) TouchProviderSession(ctx context.Context, sessionID, serial, accountID, providerKey string, lastSeen time.Time) error {
	_, err := s.pool.Exec(ctx,
		`UPDATE provider_sessions
		    SET last_seen = $2,
		        serial_number = CASE WHEN serial_number = '' THEN $3 ELSE serial_number END,
		        account_id    = CASE WHEN account_id = ''    THEN $4 ELSE account_id    END,
		        provider_key  = CASE WHEN provider_key = ''  THEN $5 ELSE provider_key  END
		  WHERE session_id = $1 AND disconnected_at IS NULL`,
		sessionID, lastSeen, serial, accountID, providerKey,
	)
	if err != nil {
		return fmt.Errorf("store: touch provider session: %w", err)
	}
	return nil
}

// CloseProviderSession marks the session for sessionID as ended. Implemented as
// an upsert so it is correct regardless of whether the async OpenProviderSession
// has landed yet: if the row is missing (close raced ahead of open on a fast
// connect→disconnect) it inserts an already-closed row; if open, it closes it;
// if already closed, it leaves the original disconnect timestamp/reason intact.
func (s *PostgresStore) CloseProviderSession(ctx context.Context, sessionID, reason string, when time.Time) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_sessions (session_id, connected_at, last_seen, disconnected_at, disconnect_reason)
		 VALUES ($1, $3, $3, $3, $2)
		 ON CONFLICT (session_id) DO UPDATE
		    SET disconnected_at = COALESCE(provider_sessions.disconnected_at, EXCLUDED.disconnected_at),
		        disconnect_reason = CASE WHEN provider_sessions.disconnected_at IS NULL
		                                 THEN EXCLUDED.disconnect_reason
		                                 ELSE provider_sessions.disconnect_reason END`,
		sessionID, reason, when,
	)
	if err != nil {
		return fmt.Errorf("store: close provider session: %w", err)
	}
	return nil
}

// CloseOpenProviderSessions closes open sessions whose last heartbeat predates
// staleBefore (orphaned by a prior coordinator process), setting disconnected_at
// to the last heartbeat seen. The last_seen < staleBefore fence prevents a
// blue-green deploy from truncating a session still live (and being touched) on
// the old instance over the shared DB — its last_seen stays fresh.
//
// Note: crash-path disconnected_at granularity is bounded by how often last_seen
// advances. Heartbeats touch it (TouchProviderSession), so the recorded
// disconnect can lag the true last-seen by at most the heartbeat interval.
func (s *PostgresStore) CloseOpenProviderSessions(ctx context.Context, staleBefore time.Time) (int, error) {
	tag, err := s.pool.Exec(ctx,
		`UPDATE provider_sessions
		    SET disconnected_at = last_seen, disconnect_reason = 'coordinator_restart'
		  WHERE disconnected_at IS NULL AND last_seen < $1`,
		staleBefore,
	)
	if err != nil {
		return 0, fmt.Errorf("store: close open provider sessions: %w", err)
	}
	return int(tag.RowsAffected()), nil
}
