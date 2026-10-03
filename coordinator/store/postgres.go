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
// NewPostgres applies pending schema migrations before it returns
// (postgres_migrations.go).

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Compile-time check that PostgresStore implements Store.
var _ Store = (*PostgresStore)(nil)

// PostgresStore is a PostgreSQL-backed implementation of Store.
type PostgresStore struct {
	pool *pgxpool.Pool

	// afterCacheRoutingResetMarker, when set (tests only), runs once
	// ResetCacheRoutingState has recorded the in-progress marker and before
	// it deletes anything: the point an interrupted reset is observed from.
	afterCacheRoutingResetMarker func()

	// In-memory cache for model prices. Keyed by "accountID:model".
	// Eliminates a DB round trip on every inference request for
	// platform pricing lookups (which change rarely).
	priceCacheMu sync.RWMutex
	priceCache   map[string]cachedPrice
}

type cachedPrice struct {
	price ModelPrice
	at    time.Time
}

// NewPostgres creates a new PostgresStore connected to the given database URL.
// It applies pending schema migrations before it returns.
func NewPostgres(ctx context.Context, scfg Config) (*PostgresStore, error) {
	return newPostgresWithPoolConfig(ctx, scfg, nil)
}

// newPostgresWithPoolConfig is NewPostgres with a hook that may adjust the
// parsed pool configuration before the pool is created. Production passes nil;
// package tests use it to attach a pgx query tracer.
func newPostgresWithPoolConfig(ctx context.Context, scfg Config, tune func(*pgxpool.Config)) (*PostgresStore, error) {
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
	if tune != nil {
		tune(cfg)
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: connect to postgres: %w", err)
	}

	// Verify connectivity.
	pingStarted := time.Now()
	pingErr := pool.Ping(ctx)
	logStartupMigration("connect", pingStarted, pingErr)
	if err := pingErr; err != nil {
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

// ensureProviderEarningsJobIndex creates the partial UNIQUE index that backs the
// `ON CONFLICT (job_id) WHERE job_id <> ” DO NOTHING` idempotency used by
// RecordProviderEarning and CreditProviderAccount.
//
// DAR-349: this MUST stay cheap and non-blocking on the serving startup path.
//   - Fast path: if a valid index already exists, return immediately (a
//     database that already has the index does no work here).
//   - It NEVER deletes rows. If existing data would violate uniqueness it fails
//     loudly with an actionable message rather than running a destructive,
//     table-locking cleanup at boot (the original outage).
//   - The build is CONCURRENTLY so a blue-green old coordinator still writing to
//     provider_earnings is never lock-blocked, and uses the simple query protocol
//     because CREATE INDEX CONCURRENTLY cannot run inside the extended protocol's
//     implicit transaction.
func (s *PostgresStore) ensureProviderEarningsJobIndex(ctx context.Context) error {
	const idxName = "idx_provider_earnings_job"

	// Already present AND valid? No-op fast path.
	var valid bool
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE((
			SELECT i.indisvalid
			FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
			WHERE c.relname = $1
		), false)`, idxName).Scan(&valid); err != nil {
		return fmt.Errorf("store: check %s: %w", idxName, err)
	}
	if valid {
		return nil
	}

	// A leftover *invalid* index from a previously interrupted CONCURRENTLY build
	// would make CREATE ... IF NOT EXISTS a silent no-op, so drop it first.
	if _, err := s.pool.Exec(ctx, `DROP INDEX IF EXISTS `+idxName); err != nil {
		return fmt.Errorf("store: drop invalid %s: %w", idxName, err)
	}

	// Verify the data can support a UNIQUE index. We do NOT dedupe at boot.
	var dupGroups int64
	if err := s.pool.QueryRow(ctx, `
		SELECT count(*) FROM (
			SELECT 1 FROM provider_earnings
			WHERE job_id <> '' GROUP BY job_id HAVING count(*) > 1
		) d`).Scan(&dupGroups); err != nil {
		return fmt.Errorf("store: count duplicate provider_earnings job_ids: %w", err)
	}
	if dupGroups > 0 {
		return fmt.Errorf("store: %d duplicate provider_earnings.job_id group(s) block unique index %s; "+
			"run the offline dedupe (coordinator/store/migrations/dedupe_provider_earnings.sql) before deploying "+
			"— boot does NOT auto-dedupe (DAR-349)", dupGroups, idxName)
	}

	// Build CONCURRENTLY on a dedicated connection via the simple query protocol.
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("store: acquire conn for %s: %w", idxName, err)
	}
	defer conn.Release()
	mrr := conn.Conn().PgConn().Exec(ctx,
		`CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_provider_earnings_job ON provider_earnings(job_id) WHERE job_id <> ''`)
	if _, err := mrr.ReadAll(); err != nil {
		return fmt.Errorf("store: create %s concurrently: %w", idxName, err)
	}
	return nil
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

// UsageByConsumer returns usage records for a specific consumer key.
func (s *PostgresStore) UsageByConsumer(consumerKey string) []UsageRecord {
	h := hashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, cached_tokens, completion_tokens, created_at, request_id, cost_micro_usd
			 FROM usage WHERE consumer_key_hash = $1 ORDER BY created_at DESC LIMIT 100`, h)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		if err := rows.Scan(&r.ProviderID, &r.ConsumerKey, &r.Model, &r.PublicModel, &r.PromptTokens, &r.CachedTokens, &r.CompletionTokens, &r.CreatedAt, &r.RequestID, &r.CostMicroUSD); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}

// RecordUsage inserts a usage row (consumer key stored as its hash) and folds
// the token counts into usage_totals in the same statement. Cached tokens are
// a subset of prompt tokens, so the totals count prompt tokens once. A failed
// insert is logged rather than returned: billing has already settled, but a
// missing row is an audit gap (usage history, per-key spend) that must not
// disappear silently.
func (s *PostgresStore) RecordUsage(rec UsageRecord) {
	h := hashKey(rec.ConsumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`WITH ins AS (
			INSERT INTO usage (provider_id, consumer_key_hash, key_id, model, public_model, prompt_tokens, cached_tokens, completion_tokens, request_id, cost_micro_usd, request_location)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		)
		UPDATE usage_totals SET
			total_requests = total_requests + 1,
			total_prompt_tokens = total_prompt_tokens + $6,
			total_completion_tokens = total_completion_tokens + $8
		WHERE id = 1`,
		rec.ProviderID, h, rec.KeyID, rec.Model, rec.PublicModel, rec.PromptTokens, rec.CachedTokens, rec.CompletionTokens,
		rec.RequestID, rec.CostMicroUSD, marshalProviderLocation(rec.RequestLocation),
	)
	if err != nil {
		slog.Error("store: record usage failed", "request_id", rec.RequestID, "model", rec.Model, "error", err)
	}
}

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
			requires_vision, has_tools, self_route_only, prefer_owner,
			final_status, error_code, error_class, prompt_tokens, completion_tokens, reasoning_tokens, cost_micro_usd,
			actual_ttft_ms, dispatch_to_first_chunk_ms, total_duration_ms,
			created_at, updated_at,
			provider_region, consumer_region,
			parse_ms, reserve_ms, route_ms, encrypt_ms, queue_wait_ms, dispatch_ms, actual_decode_tps,
			admitted_but_failed, used_backup, backup_won, error_reason`

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
			&r.RequiresVision, &r.HasTools, &r.SelfRouteOnly, &r.PreferOwner,
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

func nullSince(since time.Time) any {
	if since.IsZero() {
		return nil
	}
	return since
}

// UsageCountSince returns the number of usage records created at or after the
// given time. Uses idx_usage_created for an index-only count. A statement that
// cannot complete is reported as an error, never as a zero count.
func (s *PostgresStore) UsageCountSince(since time.Time) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var count int64
	if err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM usage
		 WHERE ($1::timestamptz IS NULL OR created_at >= $1)`,
		nullSince(since),
	).Scan(&count); err != nil {
		return 0, fmt.Errorf("store: usage count: %w", err)
	}
	return count, nil
}

// UsageTotals returns aggregated lifetime totals from the materialized
// usage_totals counter row. This is a single PK lookup — O(1) regardless
// of how many rows exist in the usage table. A statement that cannot complete
// is reported as an error, never as zero totals. Boot guarantees the row
// (checkRetiredBackfills seeds it on an empty usage table and refuses to
// start without it), so the no-row case reads as zero only if the row is
// deleted while the coordinator runs.
func (s *PostgresStore) UsageTotals() (UsageTotals, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t UsageTotals
	err := s.pool.QueryRow(ctx,
		`SELECT total_requests, total_prompt_tokens, total_completion_tokens
		 FROM usage_totals WHERE id = 1`,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens)
	if errors.Is(err, pgx.ErrNoRows) {
		return UsageTotals{}, nil
	}
	if err != nil {
		return UsageTotals{}, fmt.Errorf("store: usage totals: %w", err)
	}
	return t, nil
}

// UsageTotalsSince returns aggregate usage at or after `since`. A statement
// that cannot complete is reported as an error, never as zero totals.
func (s *PostgresStore) UsageTotalsSince(since time.Time) (UsageTotals, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t UsageTotals
	if err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM usage
		 WHERE created_at >= $1`,
		since,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens); err != nil {
		return UsageTotals{}, fmt.Errorf("store: usage totals since: %w", err)
	}
	return t, nil
}

// UsageTimeSeries returns usage buckets at or after `since` using a bounded,
// caller-selected interval so long windows do not return tens of thousands of
// minute rows. A statement that cannot complete — including one that times
// out mid-iteration — is reported as an error, never as a partial series.
func (s *PostgresStore) UsageTimeSeries(since, until time.Time, bucketSize time.Duration) ([]UsageBucket, error) {
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
		return nil, fmt.Errorf("store: usage time series: %w", err)
	}
	defer rows.Close()

	var buckets []UsageBucket
	for rows.Next() {
		var b UsageBucket
		if err := rows.Scan(&b.Minute, &b.Requests, &b.PromptTokens, &b.CompletionTokens); err != nil {
			return nil, fmt.Errorf("store: usage time series: scan: %w", err)
		}
		buckets = append(buckets, b)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: usage time series: %w", err)
	}
	return limitUsageTimeSeriesBuckets(buckets), nil
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

// pgQuerier is the subset of *pgxpool.Pool and pgx.Tx the single-statement
// ledger helpers need, so one helper serves both a standalone call (pool: one
// round trip in an implicit transaction) and a caller's open transaction.
type pgQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// creditBalanceSQL credits an account and records its ledger row in ONE
// data-modifying CTE — one round trip instead of BEGIN + upsert + SELECT +
// INSERT + COMMIT. The upsert's RETURNING is the post-credit balance, so
// balance_after is exactly the value the old in-transaction SELECT read; the
// ledger INSERT runs exactly once, to completion, under the row lock the
// upsert took, so concurrent credits/debits on the account still serialize
// on that one lock and no update is lost. Unknown accounts are created and
// zero or negative amounts are applied and recorded, exactly as before.
const creditBalanceSQL = `
		WITH credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, updated_at)
			VALUES ($1, $2, NOW())
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + $2,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT $1, $3, $2, balance_micro_usd, $4, COALESCE($5::timestamptz, NOW())
			FROM credit
		)
		SELECT balance_micro_usd FROM credit`

// creditWithdrawableBalanceSQL is creditBalanceSQL that also raises the
// withdrawable subset by the same amount.
const creditWithdrawableBalanceSQL = `
		WITH credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			VALUES ($1, $2, $2, NOW())
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + $2,
			  withdrawable_micro_usd = balances.withdrawable_micro_usd + $2,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT $1, $3, $2, balance_micro_usd, $4, COALESCE($5::timestamptz, NOW())
			FROM credit
		)
		SELECT balance_micro_usd FROM credit`

// creditBalance applies creditBalanceSQL through q (the pool for a standalone
// credit, or the caller's transaction). A zero createdAt records NOW().
func creditBalance(ctx context.Context, q pgQuerier, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, createdAt time.Time) error {
	var balanceAfter int64
	if err := q.QueryRow(ctx, creditBalanceSQL,
		accountID, amountMicroUSD, string(entryType), reference, nullableCreatedAt(createdAt),
	).Scan(&balanceAfter); err != nil {
		return fmt.Errorf("store: credit balance: %w", err)
	}
	return nil
}

// creditWithdrawableBalance applies creditWithdrawableBalanceSQL through q.
func creditWithdrawableBalance(ctx context.Context, q pgQuerier, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, createdAt time.Time) error {
	var balanceAfter int64
	if err := q.QueryRow(ctx, creditWithdrawableBalanceSQL,
		accountID, amountMicroUSD, string(entryType), reference, nullableCreatedAt(createdAt),
	).Scan(&balanceAfter); err != nil {
		return fmt.Errorf("store: credit withdrawable balance: %w", err)
	}
	return nil
}

// Credit adds micro-USD to an account and records a ledger entry (atomic).
func (s *PostgresStore) Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// One statement, one round trip: the balance upsert and its ledger row
	// still commit together or not at all (creditBalanceSQL).
	return creditBalance(ctx, s.pool, accountID, amountMicroUSD, entryType, reference, time.Time{})
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
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// One statement, one round trip (creditWithdrawableBalanceSQL).
	return creditWithdrawableBalance(ctx, s.pool, accountID, amountMicroUSD, entryType, reference, time.Time{})
}

// CreditWithdrawableOnce credits only if no ledger entry with the same
// (entryType, reference) exists yet. A transaction-scoped advisory lock on
// the reference serializes concurrent deliveries of the same webhook so the
// existence check can't race its own insert.
func (s *PostgresStore) CreditWithdrawableOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

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
	if err := creditWithdrawableBalance(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
func (s *PostgresStore) Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	return debitBalance(ctx, s.pool, accountID, amountMicroUSD, entryType, reference)
}

// MigrateAccountBalance moves the full balance (and withdrawable subset) from
// one account ID to another in a single transaction. No-op (false) when the
// source has no balance row or a zero balance.
func (s *PostgresStore) MigrateAccountBalance(from, to string) (bool, error) {
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
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("store: referrer lookup: %w", err)
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
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("store: lookup referrer: %w", err)
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
		`INSERT INTO billing_sessions (id, account_id, payment_method, amount_micro_usd, external_id, status, referral_code)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		session.ID, session.AccountID, session.PaymentMethod,
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
		`SELECT id, account_id, payment_method, amount_micro_usd, external_id, status, referral_code, created_at, completed_at
		 FROM billing_sessions WHERE id = $1`, sessionID,
	).Scan(&bs.ID, &bs.AccountID, &bs.PaymentMethod,
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

// --- Custom Pricing ---

func (s *PostgresStore) SetModelPrice(price ModelPrice) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO model_prices (account_id, model, input_price, output_price, cache_read_price, updated_at)
		 VALUES ($1, $2, $3, $4, $5, NOW())
		 ON CONFLICT (account_id, model) DO UPDATE SET
		   input_price = $3, output_price = $4, cache_read_price = $5, updated_at = NOW()`,
		price.AccountID, price.Model, price.InputPrice, price.OutputPrice, price.CacheReadPrice,
	)
	if err != nil {
		return fmt.Errorf("store: set model price: %w", err)
	}

	// Invalidate cache.
	key := price.AccountID + ":" + price.Model
	s.priceCacheMu.Lock()
	delete(s.priceCache, key)
	s.priceCacheMu.Unlock()

	return nil
}

func (s *PostgresStore) GetModelPrice(accountID, model string) (ModelPrice, bool) {
	key := accountID + ":" + model

	// Check in-memory cache (30-second TTL).
	s.priceCacheMu.RLock()
	if cached, ok := s.priceCache[key]; ok && time.Since(cached.at) < 30*time.Second {
		s.priceCacheMu.RUnlock()
		return cached.price.clone(), true
	}
	s.priceCacheMu.RUnlock()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	mp := ModelPrice{AccountID: accountID, Model: model}
	err := s.pool.QueryRow(ctx,
		`SELECT input_price, output_price, cache_read_price FROM model_prices WHERE account_id = $1 AND model = $2`,
		accountID, model,
	).Scan(&mp.InputPrice, &mp.OutputPrice, &mp.CacheReadPrice)
	if err != nil {
		return ModelPrice{}, false
	}

	// Populate cache.
	s.priceCacheMu.Lock()
	s.priceCache[key] = cachedPrice{price: mp.clone(), at: time.Now()}
	s.priceCacheMu.Unlock()

	return mp, true
}

func (s *PostgresStore) ListModelPrices(accountID string) []ModelPrice {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT account_id, model, input_price, output_price, cache_read_price FROM model_prices WHERE account_id = $1 ORDER BY model`,
		accountID,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var prices []ModelPrice
	for rows.Next() {
		var mp ModelPrice
		if err := rows.Scan(&mp.AccountID, &mp.Model, &mp.InputPrice, &mp.OutputPrice, &mp.CacheReadPrice); err != nil {
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

func scanUser(row rowScanner) (*User, error) {
	var u User
	if err := row.Scan(&u.AccountID, &u.PrivyUserID, &u.Email, &u.Role, &u.PlatformFeePercent,
		&u.StripeAccountID, &u.StripeAccountStatus, &u.StripeAccountCountry,
		&u.StripeDestinationType, &u.StripeDestinationLast4, &u.StripeInstantEligible, &u.CreatedAt); err != nil {
		return nil, err
	}
	return &u, nil
}

// wrapUserScanError preserves the historical "store: user not found: ..."
// message for every scan failure, and additionally tags a true miss
// (pgx.ErrNoRows) with ErrNotFound so callers -- including the read-through
// cache -- can distinguish "no such user" from a transient DB error with
// errors.Is. ErrNotFound.Error() is exactly "not found", so the rendered
// string is byte-for-byte unchanged.
func wrapUserScanError(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("store: user %w: %w", ErrNotFound, err)
	}
	return fmt.Errorf("store: user not found: %w", err)
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
		return nil, wrapUserScanError(err)
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
		return nil, wrapUserScanError(err)
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

// CreateStripeWithdrawalWithDebit atomically debits both balance columns
// (recording the ledger entry) and inserts the withdrawal row in a single
// transaction — a crash can no longer leave a debited balance with no
// withdrawal row. Returns ErrInsufficientBalance when the guarded debit
// matches no row.
func (s *PostgresStore) CreateStripeWithdrawalWithDebit(w *StripeWithdrawal, entryType LedgerEntryType, reference string) error {
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

	// Guarded dual-column debit: both the total and withdrawable balances
	// must cover the amount, so the debit is symmetric with CreditWithdrawable
	// refunds.
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

	return tx.Commit(ctx)
}

const stripeWithdrawalSelectColumns = `id, account_id, stripe_account_id, transfer_id, payout_id, sweep_payout_id,
	amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
	failure_reason, refunded, fee_refunded, created_at, updated_at`

func scanStripeWithdrawal(row rowScanner) (*StripeWithdrawal, error) {
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
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx,
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
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
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
	return tag.RowsAffected() > 0, nil
}

// ReopenStripeWithdrawalAfterPayoutFailure atomically reopens a bounced
// withdrawal for sweep retry with an in-database guard (see interface doc).
func (s *PostgresStore) ReopenStripeWithdrawalAfterPayoutFailure(id, failureReason string, feeRefunded bool) (bool, error) {
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE stripe_withdrawals
		 SET status = 'transferred',
		     payout_id = '',
		     failure_reason = $2,
		     fee_refunded = (fee_refunded OR $3),
		     updated_at = NOW()
		 WHERE id = $1
		   AND refunded = FALSE
		   AND status <> 'failed'`,
		id, failureReason, feeRefunded,
	)
	if err != nil {
		return false, fmt.Errorf("store: reopen stripe withdrawal: %w", err)
	}
	return tag.RowsAffected() > 0, nil
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
		release.MetallibHash, "", "", release.TemplateHashes, // retired python_hash, runtime_hash columns
		release.URL, release.Changelog,
	)
	if err != nil {
		return fmt.Errorf("store: set release: %w", err)
	}
	return nil
}

func (s *PostgresStore) ListReleases() []Release {
	releases, _ := s.ListReleasesWithError()
	return releases
}

func (s *PostgresStore) ListReleasesWithError() ([]Release, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT version, platform, COALESCE(backend, ''), binary_hash, bundle_hash, COALESCE(metallib_hash, ''),
		        COALESCE(template_hashes, ''),
		        url, changelog, active, created_at
		 FROM releases ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list releases: %w", err)
	}
	defer rows.Close()

	var releases []Release
	for rows.Next() {
		var r Release
		if err := rows.Scan(&r.Version, &r.Platform, &r.Backend, &r.BinaryHash, &r.BundleHash, &r.MetallibHash,
			&r.TemplateHashes,
			&r.URL, &r.Changelog, &r.Active, &r.CreatedAt); err != nil {
			return nil, fmt.Errorf("store: scan release: %w", err)
		}
		releases = append(releases, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate releases: %w", err)
	}
	return releases, nil
}

func (s *PostgresStore) GetLatestRelease(platform string) *Release {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT version, platform, COALESCE(backend, ''), binary_hash, bundle_hash, COALESCE(metallib_hash, ''),
		        COALESCE(template_hashes, ''),
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
			&r.TemplateHashes,
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
		`WITH earning AS (INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		 ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING
		 RETURNING account_id, model, amount_micro_usd, prompt_tokens, completion_tokens
		)
		INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
		SELECT account_id, 'account', CASE WHEN model = 'base_reward' THEN 0 ELSE 1 END, amount_micro_usd,
		 CASE WHEN model = 'base_reward' THEN 0 ELSE prompt_tokens END,
		 CASE WHEN model = 'base_reward' THEN 0 ELSE completion_tokens END, NOW() FROM earning WHERE account_id <> ''
		ON CONFLICT (key, key_type) DO UPDATE SET
		 total_count = earnings_summary.total_count + EXCLUDED.total_count,
		 total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
		 total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
		 total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
		 updated_at = NOW()`,
		earning.AccountID, earning.ProviderID, earning.ProviderKey, earning.JobID,
		earning.Model, earning.AmountMicroUSD, earning.PromptTokens, earning.CompletionTokens,
		createdAt,
	)
	if err != nil {
		return fmt.Errorf("store: insert provider earning: %w", err)
	}
	return nil
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

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning.
//
// Single-statement CTE: upsert balance, insert ledger entry, insert earning --
// all in one round trip. The old implementation used 6 sequential round trips
// (BEGIN + upsert + SELECT balance + INSERT ledger + INSERT earning + COMMIT).
func (s *PostgresStore) CreditProviderAccount(earning *ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	return creditProviderAccount(ctx, s.pool, earning)
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

	return upsertProviderRecord(ctx, s.pool, p)
}

func upsertProviderRecord(ctx context.Context, db providerRecordDB, p ProviderRecord) error {
	_, err := db.Exec(ctx,
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
		p.Version, p.RuntimeVerified, "", "", // retired python_hash, runtime_hash columns
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
			version, runtime_verified,
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
			&p.Version, &p.RuntimeVerified,
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

// --- Provider Reputation Persistence ---

func (s *PostgresStore) UpsertReputation(ctx context.Context, providerID string, rep ReputationRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	return upsertReputationRecord(ctx, s.pool, providerID, rep)
}

func upsertReputationRecord(ctx context.Context, db providerRecordDB, providerID string, rep ReputationRecord) error {
	_, err := db.Exec(ctx,
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
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("store: reputation not found: %w", ErrNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("store: read reputation: %w", err)
	}
	return &rep, nil
}

// --- APNs code-identity attestation reuse cache (W5 Fix 2) ---

func (s *PostgresStore) ListCodeAttestations(ctx context.Context) ([]CodeAttestation, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, version, attested_at, apns_token, node_public_key, binary_hash, continuous_coverage_until FROM code_attestations`)
	if err != nil {
		return nil, fmt.Errorf("store: list code attestations: %w", err)
	}
	defer rows.Close()

	var out []CodeAttestation
	for rows.Next() {
		var rec CodeAttestation
		if err := rows.Scan(
			&rec.SEPubKey, &rec.Version, &rec.AttestedAt,
			&rec.APNsToken, &rec.NodePublicKey, &rec.BinaryHash, &rec.ContinuousCoverageUntil,
		); err != nil {
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
		`INSERT INTO code_attestations (
			se_pubkey, version, attested_at, apns_token, node_public_key, binary_hash, continuous_coverage_until
		 ) VALUES ($1, $2, $3, $4, $5, $6, $7)
		 ON CONFLICT (se_pubkey) DO UPDATE SET
			version = $2, attested_at = $3,
			apns_token = $4, node_public_key = $5, binary_hash = $6,
			continuous_coverage_until = CASE WHEN code_attestations.attested_at = EXCLUDED.attested_at
             AND code_attestations.version = EXCLUDED.version AND code_attestations.apns_token = EXCLUDED.apns_token
             AND code_attestations.node_public_key = EXCLUDED.node_public_key AND code_attestations.binary_hash = EXCLUDED.binary_hash
             THEN GREATEST(code_attestations.continuous_coverage_until,EXCLUDED.continuous_coverage_until)
             ELSE EXCLUDED.continuous_coverage_until END
		 WHERE code_attestations.attested_at <= EXCLUDED.attested_at`,
		rec.SEPubKey, rec.Version, rec.AttestedAt,
		rec.APNsToken, rec.NodePublicKey, rec.BinaryHash, rec.ContinuousCoverageUntil,
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

func (s *PostgresStore) ListCodeAttestPushBudgets(ctx context.Context) ([]CodeAttestPushBudget, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, token_hash, next_push_at, updated_at, last_clear_at
		   FROM code_attest_push_budgets`)
	if err != nil {
		return nil, fmt.Errorf("store: list code attest push budgets: %w", err)
	}
	defer rows.Close()
	var out []CodeAttestPushBudget
	for rows.Next() {
		var rec CodeAttestPushBudget
		var lastClear *time.Time
		if err := rows.Scan(
			&rec.SEPubKey, &rec.TokenHash, &rec.NextPushAt, &rec.UpdatedAt,
			&lastClear,
		); err != nil {
			return nil, fmt.Errorf("store: scan code attest push budget: %w", err)
		}
		if lastClear != nil {
			rec.LastClearAt = *lastClear
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate code attest push budgets: %w", err)
	}
	return out, nil
}

func (s *PostgresStore) UpsertCodeAttestPushBudget(ctx context.Context, rec CodeAttestPushBudget) error {
	if rec.SEPubKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err := s.pool.Exec(ctx,
		`INSERT INTO code_attest_push_budgets (
			se_pubkey, token_hash, next_push_at, updated_at
		 ) VALUES ($1, $2, $3, $4)
		 ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
			next_push_at = GREATEST(
				code_attest_push_budgets.next_push_at,
				EXCLUDED.next_push_at
			),
			updated_at = EXCLUDED.updated_at`,
		rec.SEPubKey, rec.TokenHash, rec.NextPushAt, rec.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("store: upsert code attest push budget: %w", err)
	}
	return nil
}

func (s *PostgresStore) DeleteCodeAttestPushBudget(ctx context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, err := s.pool.Exec(ctx,
		`DELETE FROM code_attest_push_budgets WHERE se_pubkey = $1`, seKey,
	); err != nil {
		return fmt.Errorf("store: delete code attest push budget: %w", err)
	}
	return nil
}

func (s *PostgresStore) ReserveCodeAttestPushBudget(
	ctx context.Context,
	seKey, tokenHash string,
	now, nextPushAt time.Time,
) (bool, error) {
	if seKey == "" || tokenHash == "" || !nextPushAt.After(now) {
		return false, errors.New("store: invalid code attest push reservation")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// Token row = per-token cooldown (A-B-A retention). Sentinel row
	// (token_hash = '') = per-SE-key admission floor: a NOVEL token (no row) is
	// only admitted once the floor has elapsed, so fabricated fresh tokens
	// cannot mint fresh budgets (Codex P1).
	//
	// Novel-token admission is serialized on the sentinel row itself: the floor
	// is created-or-advanced FIRST, and only the statement whose ON CONFLICT
	// guard passes against the row's latest committed version proceeds to
	// insert the token row. Two blue-green coordinators racing distinct novel
	// tokens for one SE key therefore cannot both admit — the loser re-checks
	// the winner's freshly raised floor and returns floor-blocked, even when
	// neither snapshot saw a sentinel (or a floor block) at statement start.
	var admitted bool
	err := s.pool.QueryRow(ctx,
		`WITH known AS (
			SELECT 1 FROM code_attest_push_budgets
			 WHERE se_pubkey = $1 AND token_hash = $2
		),
		floor_acquired AS (
			INSERT INTO code_attest_push_budgets (
				se_pubkey, token_hash, next_push_at, updated_at
			)
			SELECT $1, '', $4, $3
			 WHERE NOT EXISTS (SELECT 1 FROM known)
			ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
				next_push_at = EXCLUDED.next_push_at,
				updated_at = EXCLUDED.updated_at
			WHERE code_attest_push_budgets.next_push_at <= $3
			RETURNING 1
		),
		admitted AS (
			INSERT INTO code_attest_push_budgets (
				se_pubkey, token_hash, next_push_at, updated_at
			)
			SELECT $1, $2, $4, $3
			 WHERE EXISTS (SELECT 1 FROM known)
			    OR EXISTS (SELECT 1 FROM floor_acquired)
			ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
				next_push_at = EXCLUDED.next_push_at,
				updated_at = EXCLUDED.updated_at
			WHERE code_attest_push_budgets.next_push_at <= $3
			RETURNING 1
		),
		floor_raised AS (
			-- Known-token admissions raise the floor too; novel admissions
			-- already set it in floor_acquired. The two paths are mutually
			-- exclusive, so the sentinel row is written at most once here.
			INSERT INTO code_attest_push_budgets (
				se_pubkey, token_hash, next_push_at, updated_at
			)
			SELECT $1, '', $4, $3
			  FROM admitted
			 WHERE EXISTS (SELECT 1 FROM known)
			ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
				next_push_at = GREATEST(
					code_attest_push_budgets.next_push_at,
					EXCLUDED.next_push_at
				),
				updated_at = EXCLUDED.updated_at
		)
		SELECT EXISTS (SELECT 1 FROM admitted)`,
		seKey, tokenHash, now, nextPushAt,
	).Scan(&admitted)
	if err != nil {
		return false, fmt.Errorf("store: reserve code attest push budget: %w", err)
	}
	if admitted {
		// Bound rows per SE key: keep the newest token rows plus the floor
		// sentinel. Best-effort — a failure only delays GC to the next push.
		if _, err := s.pool.Exec(ctx,
			`DELETE FROM code_attest_push_budgets
			  WHERE se_pubkey = $1 AND token_hash <> ''
			    AND token_hash NOT IN (
				SELECT token_hash FROM code_attest_push_budgets
				 WHERE se_pubkey = $1 AND token_hash <> ''
				 ORDER BY updated_at DESC, token_hash DESC
				 LIMIT $2
			    )`,
			seKey, CodeAttestPushBudgetMaxTokenRows,
		); err != nil {
			return true, nil
		}
	}
	return admitted, nil
}

// ClearCodeAttestPushFloor drops the per-SE-key novel-token admission floor so
// a genuinely rotated token can be challenged promptly. Per-token cooldown rows
// are untouched (A-B-A retention). The clear is compare-and-set on the
// sentinel's durable last_clear_at: it is honored only when the previous
// durable clear is at least cooldown old (NULL = never cleared → honored), so
// the anti-abuse spacing between rotation clears holds across coordinator
// restarts and blue-green peers — not just within one process. The sentinel row
// is kept (next_push_at=now lifts the floor; last_clear_at=now starts the next
// cooldown). Returns the durable last-clear instant (now when honored, the
// pre-statement one when throttled) and whether the clear was honored.
func (s *PostgresStore) ClearCodeAttestPushFloor(
	ctx context.Context, seKey string, now time.Time, cooldown time.Duration,
) (time.Time, bool, error) {
	if seKey == "" {
		return time.Time{}, false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var (
		cleared   bool
		lastClear time.Time
	)
	// The outer SELECT sees the pre-statement snapshot (data-modifying CTE
	// semantics); when the CAS wins the caller's last-clear is `now`, so the
	// snapshot value is only reported on the throttled path. COALESCE covers
	// the no-sentinel / never-cleared cases conservatively with `now`.
	err := s.pool.QueryRow(ctx,
		`WITH cleared AS (
			INSERT INTO code_attest_push_budgets (
				se_pubkey, token_hash, next_push_at, updated_at, last_clear_at
			) VALUES ($1, '', $2, $2, $2)
			ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
				next_push_at = EXCLUDED.next_push_at,
				updated_at = EXCLUDED.updated_at,
				last_clear_at = EXCLUDED.last_clear_at
			WHERE code_attest_push_budgets.last_clear_at IS NULL
			   OR code_attest_push_budgets.last_clear_at <= $3
			RETURNING 1
		)
		SELECT EXISTS (SELECT 1 FROM cleared),
		       COALESCE((
			SELECT last_clear_at FROM code_attest_push_budgets
			 WHERE se_pubkey = $1 AND token_hash = ''
		       ), $2)`,
		seKey, now, now.Add(-cooldown),
	).Scan(&cleared, &lastClear)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("store: clear code attest push floor: %w", err)
	}
	if cleared {
		lastClear = now
	}
	return lastClear, cleared, nil
}

// --- Durable provider device evidence ---

func (s *PostgresStore) ListProviderTrustReuse(ctx context.Context) ([]ProviderTrustReuse, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, serial, trust_level, last_verified_binary_hash,
		        sip_enabled, secure_boot_full, mda_udid,
		        hardware_proof_verified_at, application_proof_verified_at,
		        continuous_coverage_until,
		        evidence_generation, revocation_generation,
		        revocation_event_id, revoked_at
		   FROM provider_trust_reuse`)
	if err != nil {
		return nil, fmt.Errorf("store: list provider trust reuse: %w", err)
	}
	defer rows.Close()

	var out []ProviderTrustReuse
	for rows.Next() {
		var rec ProviderTrustReuse
		if err := rows.Scan(
			&rec.SEPubKey, &rec.Serial, &rec.TrustLevel,
			&rec.LastVerifiedBinaryHash, &rec.SIPEnabled,
			&rec.SecureBootFull, &rec.MDAUDID,
			&rec.HardwareProofVerifiedAt, &rec.ApplicationProofVerifiedAt,
			&rec.ContinuousCoverageUntil,
			&rec.EvidenceGeneration, &rec.RevocationGeneration,
			&rec.RevocationEventID, &rec.RevokedAt,
		); err != nil {
			return nil, fmt.Errorf("store: scan provider trust reuse: %w", err)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate provider trust reuse: %w", err)
	}
	return out, nil
}

func (s *PostgresStore) UpsertProviderTrustReuse(ctx context.Context, rec ProviderTrustReuse, expectedRevocationGeneration uint64) (ProviderTrustReuseWriteResult, error) {
	if rec.SEPubKey == "" {
		return ProviderTrustReuseWriteResult{}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var result ProviderTrustReuseWriteResult
	err := s.pool.QueryRow(ctx,
		`WITH written AS (
			INSERT INTO provider_trust_reuse (
				se_pubkey, serial, trust_level, binary_hash,
				last_verified_binary_hash, sip_enabled, secure_boot_full, mda_udid,
				verified_at, hardware_proof_verified_at,
				application_proof_verified_at, continuous_coverage_until,
				evidence_generation,
				revocation_generation, revocation_event_id, revoked_at)
			 VALUES ($1,$2,$3,$4,$4,$5,$6,$7,$8,$8,$9,$12,1,$10,$11,NULL)
			 ON CONFLICT (se_pubkey) DO UPDATE SET
				serial = EXCLUDED.serial,
				trust_level = EXCLUDED.trust_level,
				binary_hash = EXCLUDED.binary_hash,
				last_verified_binary_hash = EXCLUDED.last_verified_binary_hash,
				sip_enabled = EXCLUDED.sip_enabled,
				secure_boot_full = EXCLUDED.secure_boot_full,
				mda_udid = EXCLUDED.mda_udid,
				verified_at = EXCLUDED.verified_at,
				hardware_proof_verified_at = EXCLUDED.hardware_proof_verified_at,
				application_proof_verified_at = EXCLUDED.application_proof_verified_at,
				continuous_coverage_until = GREATEST(
					provider_trust_reuse.continuous_coverage_until,
					EXCLUDED.continuous_coverage_until),
				evidence_generation = provider_trust_reuse.evidence_generation + 1
			 WHERE provider_trust_reuse.revoked_at IS NULL
			   AND provider_trust_reuse.revocation_generation = EXCLUDED.revocation_generation
			 RETURNING evidence_generation, revocation_generation
		)
		SELECT TRUE, evidence_generation, revocation_generation FROM written
		UNION ALL
		SELECT FALSE, evidence_generation, revocation_generation
		  FROM provider_trust_reuse
		 WHERE se_pubkey = $1 AND NOT EXISTS (SELECT 1 FROM written)
		LIMIT 1`,
		rec.SEPubKey, rec.Serial, rec.TrustLevel,
		rec.LastVerifiedBinaryHash, rec.SIPEnabled, rec.SecureBootFull,
		rec.MDAUDID, rec.HardwareProofVerifiedAt,
		rec.ApplicationProofVerifiedAt, expectedRevocationGeneration,
		rec.RevocationEventID, rec.ContinuousCoverageUntil,
	).Scan(&result.Applied, &result.EvidenceGeneration, &result.RevocationGeneration)
	if err != nil {
		return ProviderTrustReuseWriteResult{}, fmt.Errorf("store: upsert provider trust reuse: %w", err)
	}
	return result, nil
}

func (s *PostgresStore) RecoverProviderTrustReuse(ctx context.Context, rec ProviderTrustReuse, expectedRevocationGeneration uint64) (ProviderTrustReuseWriteResult, error) {
	if rec.SEPubKey == "" {
		return ProviderTrustReuseWriteResult{}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var result ProviderTrustReuseWriteResult
	err := s.pool.QueryRow(ctx,
		`WITH written AS (
			INSERT INTO provider_trust_reuse (
				se_pubkey, serial, trust_level, binary_hash,
				last_verified_binary_hash, sip_enabled, secure_boot_full, mda_udid,
				verified_at, hardware_proof_verified_at,
				application_proof_verified_at, continuous_coverage_until,
				evidence_generation,
				revocation_generation, revocation_event_id, revoked_at)
			 VALUES ($1,$2,$3,$4,$4,$5,$6,$7,$8,$8,$9,$12,1,$10,$11,NULL)
			 ON CONFLICT (se_pubkey) DO UPDATE SET
				serial = EXCLUDED.serial,
				trust_level = EXCLUDED.trust_level,
				binary_hash = EXCLUDED.binary_hash,
				last_verified_binary_hash = EXCLUDED.last_verified_binary_hash,
				sip_enabled = EXCLUDED.sip_enabled,
				secure_boot_full = EXCLUDED.secure_boot_full,
				mda_udid = EXCLUDED.mda_udid,
				verified_at = EXCLUDED.verified_at,
				hardware_proof_verified_at = EXCLUDED.hardware_proof_verified_at,
				application_proof_verified_at = EXCLUDED.application_proof_verified_at,
				continuous_coverage_until = GREATEST(
					provider_trust_reuse.continuous_coverage_until,
					EXCLUDED.continuous_coverage_until),
				evidence_generation = provider_trust_reuse.evidence_generation + 1,
				revoked_at = NULL
			 WHERE provider_trust_reuse.revocation_generation = EXCLUDED.revocation_generation
			 RETURNING evidence_generation, revocation_generation
		)
		SELECT TRUE, evidence_generation, revocation_generation FROM written
		UNION ALL
		SELECT FALSE, evidence_generation, revocation_generation
		  FROM provider_trust_reuse
		 WHERE se_pubkey = $1 AND NOT EXISTS (SELECT 1 FROM written)
		LIMIT 1`,
		rec.SEPubKey, rec.Serial, rec.TrustLevel,
		rec.LastVerifiedBinaryHash, rec.SIPEnabled, rec.SecureBootFull,
		rec.MDAUDID, rec.HardwareProofVerifiedAt,
		rec.ApplicationProofVerifiedAt, expectedRevocationGeneration,
		rec.RevocationEventID, rec.ContinuousCoverageUntil,
	).Scan(&result.Applied, &result.EvidenceGeneration, &result.RevocationGeneration)
	if err != nil {
		return ProviderTrustReuseWriteResult{}, fmt.Errorf("store: recover provider trust reuse: %w", err)
	}
	return result, nil
}

func (s *PostgresStore) RevokeProviderTrustReuse(ctx context.Context, seKey, revocationEventID string) (ProviderTrustReuse, error) {
	if seKey == "" || revocationEventID == "" {
		return ProviderTrustReuse{}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var rec ProviderTrustReuse
	err := s.pool.QueryRow(ctx,
		`WITH revoked AS (
			INSERT INTO provider_trust_reuse (
				se_pubkey, trust_level, revoked_at, revocation_generation,
				revocation_event_id)
			 VALUES ($1, '', NOW(), 1, $2)
			 ON CONFLICT (se_pubkey) DO UPDATE SET
				trust_level = '',
				revoked_at = NOW(),
				continuous_coverage_until = NULL,
				revocation_generation = provider_trust_reuse.revocation_generation + 1,
				revocation_event_id = EXCLUDED.revocation_event_id
			 WHERE provider_trust_reuse.revocation_event_id
			       IS DISTINCT FROM EXCLUDED.revocation_event_id
			 RETURNING se_pubkey, serial, trust_level,
				last_verified_binary_hash, sip_enabled, secure_boot_full,
				mda_udid, hardware_proof_verified_at,
				application_proof_verified_at, continuous_coverage_until,
				evidence_generation,
				revocation_generation, revocation_event_id, revoked_at
		)
		SELECT se_pubkey, serial, trust_level, last_verified_binary_hash,
		       sip_enabled, secure_boot_full, mda_udid,
		       hardware_proof_verified_at, application_proof_verified_at,
		       continuous_coverage_until,
		       evidence_generation, revocation_generation,
		       revocation_event_id, revoked_at
		  FROM revoked
		UNION ALL
		SELECT se_pubkey, serial, trust_level, last_verified_binary_hash,
		       sip_enabled, secure_boot_full, mda_udid,
		       hardware_proof_verified_at, application_proof_verified_at,
		       continuous_coverage_until,
		       evidence_generation, revocation_generation,
		       revocation_event_id, revoked_at
		  FROM provider_trust_reuse
		 WHERE se_pubkey = $1 AND NOT EXISTS (SELECT 1 FROM revoked)
		LIMIT 1`,
		seKey, revocationEventID,
	).Scan(
		&rec.SEPubKey, &rec.Serial, &rec.TrustLevel,
		&rec.LastVerifiedBinaryHash, &rec.SIPEnabled,
		&rec.SecureBootFull, &rec.MDAUDID,
		&rec.HardwareProofVerifiedAt, &rec.ApplicationProofVerifiedAt,
		&rec.ContinuousCoverageUntil,
		&rec.EvidenceGeneration, &rec.RevocationGeneration,
		&rec.RevocationEventID, &rec.RevokedAt,
	)
	if err != nil {
		return ProviderTrustReuse{}, fmt.Errorf("store: revoke provider trust reuse: %w", err)
	}
	return rec, nil
}

func (s *PostgresStore) AdvanceProviderTrustReuseCoverage(ctx context.Context, seKeys []string, until time.Time) error {
	if len(seKeys) == 0 || until.IsZero() {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	// One batched pass; GREATEST keeps the watermark monotonic and a
	// tombstoned/non-hardware row is never touched (revocation wins).
	_, err := s.pool.Exec(ctx,
		`UPDATE provider_trust_reuse
		    SET continuous_coverage_until = GREATEST(continuous_coverage_until, $2::timestamptz)
		  WHERE se_pubkey = ANY($1)
		    AND revoked_at IS NULL
		    AND trust_level = 'hardware'`,
		seKeys, until)
	if err != nil {
		return fmt.Errorf("store: advance provider trust reuse coverage: %w", err)
	}
	return nil
}

// --- Bounded durable MDM/MDA verification scheduler ---

const verificationJobColumns = `se_pubkey, serial, udid, task_kind, task_state,
	priority, retry_stage, previous_delay_ns, next_attempt_at, last_outcome,
	reopen_pending, updated_at, claim_owner, claim_expires_at`

func scanVerificationJob(row rowScanner) (VerificationJob, error) {
	var rec VerificationJob
	var previousDelayNS int64
	var nextAttemptAt *time.Time
	if err := row.Scan(
		&rec.SEPubKey, &rec.Serial, &rec.UDID, &rec.Kind, &rec.State,
		&rec.Priority, &rec.RetryStage, &previousDelayNS, &nextAttemptAt,
		&rec.LastOutcome, &rec.ReopenPending, &rec.UpdatedAt,
		&rec.ClaimOwner, &rec.ClaimExpiresAt,
	); err != nil {
		return VerificationJob{}, err
	}
	rec.PreviousDelay = time.Duration(previousDelayNS)
	if nextAttemptAt != nil {
		rec.NextAttemptAt = *nextAttemptAt
	}
	return rec, nil
}

func (s *PostgresStore) UpsertVerificationJob(ctx context.Context, rec VerificationJob) (VerificationJob, error) {
	if rec.SEPubKey == "" || rec.Kind == "" {
		return VerificationJob{}, errors.New("store: verification job requires SE key and kind")
	}
	if rec.LastOutcome == "" {
		rec.LastOutcome = VerificationOutcomeNone
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`INSERT INTO provider_verification_jobs (
			se_pubkey, serial, udid, task_kind, task_state, priority,
			retry_stage, previous_delay_ns, next_attempt_at, last_outcome,
			updated_at, claim_owner, claim_expires_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,'',NULL)
		 ON CONFLICT (se_pubkey, task_kind) DO UPDATE SET
			serial = EXCLUDED.serial,
			udid = CASE WHEN EXCLUDED.udid <> '' THEN EXCLUDED.udid ELSE provider_verification_jobs.udid END,
			task_state = CASE
				WHEN provider_verification_jobs.task_state = 'completed' THEN EXCLUDED.task_state
				WHEN provider_verification_jobs.task_state = 'waiting_challenge'
				 AND EXCLUDED.task_state = 'pending' THEN 'pending'
				ELSE provider_verification_jobs.task_state END,
			priority = CASE
				WHEN provider_verification_jobs.task_state = 'completed'
					THEN EXCLUDED.priority
				ELSE LEAST(provider_verification_jobs.priority, EXCLUDED.priority) END,
			retry_stage = CASE WHEN provider_verification_jobs.task_state = 'completed'
				THEN EXCLUDED.retry_stage ELSE provider_verification_jobs.retry_stage END,
			previous_delay_ns = CASE WHEN provider_verification_jobs.task_state = 'completed'
				THEN EXCLUDED.previous_delay_ns ELSE provider_verification_jobs.previous_delay_ns END,
			next_attempt_at = CASE
				WHEN provider_verification_jobs.task_state = 'completed' THEN EXCLUDED.next_attempt_at
				WHEN provider_verification_jobs.task_state IN ('waiting_challenge', 'running')
				 AND EXCLUDED.task_state = 'pending' THEN EXCLUDED.next_attempt_at
				ELSE provider_verification_jobs.next_attempt_at END,
			last_outcome = CASE WHEN provider_verification_jobs.task_state = 'completed'
				THEN EXCLUDED.last_outcome ELSE provider_verification_jobs.last_outcome END,
			reopen_pending = CASE
				WHEN provider_verification_jobs.task_state = 'completed' THEN FALSE
				WHEN provider_verification_jobs.task_state = 'running'
				 AND EXCLUDED.task_state = 'pending' THEN TRUE
				ELSE provider_verification_jobs.reopen_pending END,
			updated_at = EXCLUDED.updated_at,
			claim_owner = CASE WHEN provider_verification_jobs.task_state = 'completed'
				THEN '' ELSE provider_verification_jobs.claim_owner END,
			claim_expires_at = CASE WHEN provider_verification_jobs.task_state = 'completed'
				THEN NULL ELSE provider_verification_jobs.claim_expires_at END
		 RETURNING `+verificationJobColumns,
		rec.SEPubKey, rec.Serial, rec.UDID, rec.Kind, rec.State, rec.Priority,
		rec.RetryStage, int64(rec.PreviousDelay), nullableVerificationTime(rec.NextAttemptAt),
		rec.LastOutcome, rec.UpdatedAt,
	)
	out, err := scanVerificationJob(row)
	if err != nil {
		return VerificationJob{}, fmt.Errorf("store: upsert verification job: %w", err)
	}
	return out, nil
}

func nullableVerificationTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}

func (s *PostgresStore) GetVerificationJob(ctx context.Context, seKey string, kind VerificationTaskKind) (*VerificationJob, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rec, err := scanVerificationJob(s.pool.QueryRow(ctx,
		`SELECT `+verificationJobColumns+`
		   FROM provider_verification_jobs
		  WHERE se_pubkey = $1 AND task_kind = $2`, seKey, kind))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("store: get verification job: %w", err)
	}
	return &rec, nil
}

func (s *PostgresStore) ListDueVerificationJobs(
	ctx context.Context,
	now time.Time,
	limit int,
) ([]VerificationJob, error) {
	return s.ListDueVerificationJobsPage(ctx, now, limit, 0)
}

// verificationDuePageHint caps the initial capacity of a due-rows page.
const verificationDuePageHint = 256

func (s *PostgresStore) ListDueVerificationJobsPage(
	ctx context.Context,
	now time.Time,
	limit, offset int,
) ([]VerificationJob, error) {
	if limit <= 0 || offset < 0 {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx,
		`SELECT `+verificationJobColumns+`
		   FROM provider_verification_jobs
		  WHERE (task_state IN ('pending','backoff')
		         OR (task_state = 'running' AND claim_expires_at IS NOT NULL
		             AND claim_expires_at <= $1))
		    AND next_attempt_at <= $1
		    AND (claim_owner = '' OR claim_expires_at IS NULL OR claim_expires_at <= $1)
		  ORDER BY priority, next_attempt_at, se_pubkey, task_kind
		  LIMIT $2 OFFSET $3`, now, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("store: list due verification jobs: %w", err)
	}
	defer rows.Close()
	// The page is sized for the common case, not the limit: the caller asks
	// for its whole queue capacity (4,096) every poll while only a few dozen
	// rows are usually due, and a 4,096-row pre-allocation per poll was 16 %
	// of all bytes the coordinator allocated. append grows it when needed.
	out := make([]VerificationJob, 0, min(limit, verificationDuePageHint))
	for rows.Next() {
		rec, scanErr := scanVerificationJob(rows)
		if scanErr != nil {
			return nil, fmt.Errorf("store: scan due verification job: %w", scanErr)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate due verification jobs: %w", err)
	}
	return out, nil
}

func (s *PostgresStore) ClaimVerificationJob(ctx context.Context, seKey string, kind VerificationTaskKind, owner string, now, expiresAt time.Time) (VerificationJob, bool, error) {
	if owner == "" || !expiresAt.After(now) {
		return VerificationJob{}, false, errors.New("store: invalid verification claim")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rec, err := scanVerificationJob(s.pool.QueryRow(ctx,
		`UPDATE provider_verification_jobs
		    SET task_state = 'running', reopen_pending = FALSE, claim_owner = $3,
		        claim_expires_at = $5, updated_at = $4
		  WHERE se_pubkey = $1 AND task_kind = $2
		    AND (task_state IN ('pending','backoff')
		         OR (task_state = 'running' AND claim_expires_at IS NOT NULL
		             AND claim_expires_at <= $4))
		    AND next_attempt_at <= $4
		    AND (claim_owner = '' OR claim_expires_at IS NULL OR claim_expires_at <= $4)
		  RETURNING `+verificationJobColumns,
		seKey, kind, owner, now, expiresAt))
	if errors.Is(err, pgx.ErrNoRows) {
		return VerificationJob{}, false, nil
	}
	if err != nil {
		return VerificationJob{}, false, fmt.Errorf("store: claim verification job: %w", err)
	}
	return rec, true, nil
}

func (s *PostgresStore) ReleaseVerificationJob(ctx context.Context, seKey string, kind VerificationTaskKind, owner string, now time.Time) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err := s.pool.Exec(ctx,
		`UPDATE provider_verification_jobs
		    SET task_state = 'pending', reopen_pending = FALSE,
		        claim_owner = '', claim_expires_at = NULL, updated_at = $4
		  WHERE se_pubkey = $1 AND task_kind = $2 AND claim_owner = $3`,
		seKey, kind, owner, now)
	if err != nil {
		return fmt.Errorf("store: release verification job: %w", err)
	}
	return nil
}

func (s *PostgresStore) CompleteVerificationJob(ctx context.Context, seKey string, kind VerificationTaskKind, owner string, outcome VerificationOutcome, now time.Time) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err := s.pool.Exec(ctx,
		`UPDATE provider_verification_jobs
		    SET task_state = CASE WHEN reopen_pending THEN 'pending' ELSE 'completed' END,
		        retry_stage = CASE WHEN reopen_pending THEN retry_stage ELSE 0 END,
		        previous_delay_ns = CASE WHEN reopen_pending THEN previous_delay_ns ELSE 0 END,
		        next_attempt_at = CASE WHEN reopen_pending THEN next_attempt_at ELSE NULL END,
		        last_outcome = CASE WHEN reopen_pending THEN last_outcome ELSE $4 END,
		        reopen_pending = FALSE, updated_at = $5,
		        claim_owner = '', claim_expires_at = NULL
		  WHERE se_pubkey = $1 AND task_kind = $2
		    AND (claim_owner = '' OR claim_owner = $3)`,
		seKey, kind, owner, outcome, now)
	if err != nil {
		return fmt.Errorf("store: complete verification job: %w", err)
	}
	return nil
}

func (s *PostgresStore) RescheduleVerificationJob(ctx context.Context, seKey string, kind VerificationTaskKind, owner string, priority VerificationPriority, retryStage int, previousDelay time.Duration, nextAttemptAt time.Time, outcome VerificationOutcome, now time.Time) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err := s.pool.Exec(ctx,
		`UPDATE provider_verification_jobs
		    SET task_state = CASE WHEN reopen_pending THEN 'pending' ELSE 'backoff' END,
		        priority = CASE WHEN reopen_pending THEN priority ELSE $4 END,
		        retry_stage = CASE WHEN reopen_pending THEN retry_stage ELSE $5 END,
		        previous_delay_ns = CASE WHEN reopen_pending THEN previous_delay_ns ELSE $6 END,
		        next_attempt_at = CASE WHEN reopen_pending THEN next_attempt_at ELSE $7 END,
		        last_outcome = CASE WHEN reopen_pending THEN last_outcome ELSE $8 END,
		        reopen_pending = FALSE, updated_at = $9,
		        claim_owner = '', claim_expires_at = NULL
		  WHERE se_pubkey = $1 AND task_kind = $2 AND claim_owner = $3`,
		seKey, kind, owner, priority, retryStage, int64(previousDelay),
		nextAttemptAt, outcome, now)
	if err != nil {
		return fmt.Errorf("store: reschedule verification job: %w", err)
	}
	return nil
}

// --- Provider Log Reports ---

const maxLogReportSize = 10 << 20 // 10 MB

func (s *PostgresStore) StoreLogReport(accountID string, logData []byte) (int64, error) {
	if len(logData) > maxLogReportSize {
		logData = logData[:maxLogReportSize]
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var reportID int64
	err := s.pool.QueryRow(ctx,
		`INSERT INTO provider_log_reports (account_id, log_data, log_size_bytes)
		 VALUES ($1, $2, $3)
		 RETURNING id`,
		accountID, logData, int64(len(logData)),
	).Scan(&reportID)
	if err != nil {
		return 0, fmt.Errorf("store: insert log report: %w", err)
	}
	return reportID, nil
}

func (s *PostgresStore) GetLogReport(id int64) (*LogReport, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var r LogReport
	err := s.pool.QueryRow(ctx,
		`SELECT id, account_id, log_data, log_size_bytes, created_at
		 FROM provider_log_reports WHERE id = $1`, id,
	).Scan(&r.ID, &r.AccountID, &r.LogData, &r.LogSizeBytes, &r.CreatedAt)
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
