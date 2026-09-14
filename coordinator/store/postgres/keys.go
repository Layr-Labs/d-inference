package postgres

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// apiKeyColumns is the canonical SELECT list for reading an api_keys row into
// an APIKey via scanAPIKeyRow.
const apiKeyColumns = `id, owner_account_id, name, raw_prefix, key_hash, active,
	limit_micro_usd, limit_reset, rpm_limit, itpm_limit, otpm_limit,
	allowed_models, expires_at, created_at, last_used_at, self_route_only`

// scanAPIKeyRow scans one api_keys row (selected via apiKeyColumns) into APIKey.
func scanAPIKeyRow(row rowScanner) (*contracts.APIKey, error) {
	var (
		k          contracts.APIKey
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
	k.LimitReset = contracts.NormalizeResetWindow(k.LimitReset)
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
func (s *Store) insertAPIKey(ctx context.Context, rec *contracts.APIKey, onConflictDoNothing bool) error {
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
		rec.LimitMicroUSD, contracts.NormalizeResetWindow(rec.LimitReset), rec.RPMLimit, rec.ITPMLimit, rec.OTPMLimit,
		encodeModelList(rec.AllowedModels), rec.ExpiresAt, rec.CreatedAt, rec.SelfRouteOnly,
	)
	return err
}

// CreateKey generates a cryptographically random API key, hashes it, stores
// the hash, and returns the raw key (the only time it's available in plaintext).
func (s *Store) CreateKey() (string, error) {
	raw, _, err := s.CreateAPIKey("", contracts.APIKeyCreate{})
	return raw, err
}

// CreateKeyForAccount generates a new API key linked to a specific account.
func (s *Store) CreateKeyForAccount(accountID string) (string, error) {
	raw, _, err := s.CreateAPIKey(accountID, contracts.APIKeyCreate{})
	return raw, err
}

// CreateAPIKey mints a new API key with optional per-key limits.
func (s *Store) CreateAPIKey(accountID string, opts contracts.APIKeyCreate) (string, *contracts.APIKey, error) {
	raw, err := contracts.GenerateRawKey()
	if err != nil {
		return "", nil, fmt.Errorf("store: generate key: %w", err)
	}
	id, err := contracts.GenerateKeyID()
	if err != nil {
		return "", nil, fmt.Errorf("store: generate key id: %w", err)
	}
	rec := &contracts.APIKey{
		ID:             id,
		OwnerAccountID: accountID,
		Name:           opts.Name,
		Label:          contracts.KeyLabel(raw),
		KeyHash:        contracts.HashKey(raw),
		LimitMicroUSD:  opts.LimitMicroUSD,
		LimitReset:     contracts.NormalizeResetWindow(opts.LimitReset),
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
func (s *Store) SeedKey(rawKey string) error {
	id, err := contracts.GenerateKeyID()
	if err != nil {
		return fmt.Errorf("store: generate key id: %w", err)
	}
	rec := &contracts.APIKey{
		ID:         id,
		Name:       "admin",
		Label:      contracts.KeyLabel(rawKey),
		KeyHash:    contracts.HashKey(rawKey),
		LimitReset: contracts.KeyResetNone,
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
func (s *Store) GetKeyAccount(key string) string {
	h := contracts.HashKey(key)

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
func (s *Store) ValidateKey(key string) bool {
	h := contracts.HashKey(key)

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
func (s *Store) ValidateKeyFull(key string) (bool, string, error) {
	h := contracts.HashKey(key)

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
func (s *Store) AuthenticateKey(rawKey string) (*contracts.APIKey, error) {
	h := contracts.HashKey(rawKey)

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
func (s *Store) ListAPIKeys(accountID string) ([]contracts.APIKey, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+apiKeyColumns+` FROM api_keys WHERE owner_account_id = $1 AND id <> '' ORDER BY created_at DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]contracts.APIKey, 0)
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
func (s *Store) GetAPIKeyByID(accountID, id string) (*contracts.APIKey, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+apiKeyColumns+` FROM api_keys WHERE id = $1 AND owner_account_id = $2`, id, accountID)
	return scanAPIKeyRow(row)
}

// UpdateAPIKey overwrites mutable fields of a key, scoped to the owner.
func (s *Store) UpdateAPIKey(accountID, id string, mutable contracts.APIKey) (*contracts.APIKey, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE api_keys SET
			name = $1, active = $2, limit_micro_usd = $3, limit_reset = $4,
			rpm_limit = $5, itpm_limit = $6, otpm_limit = $7,
			allowed_models = $8, expires_at = $9, self_route_only = $10
		 WHERE id = $11 AND owner_account_id = $12`,
		mutable.Name, !mutable.Disabled, mutable.LimitMicroUSD, contracts.NormalizeResetWindow(mutable.LimitReset),
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
func (s *Store) RevokeAPIKeyByID(accountID, id string) error {
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
func (s *Store) RotateAPIKey(accountID, id string) (string, *contracts.APIKey, error) {
	raw, err := contracts.GenerateRawKey()
	if err != nil {
		return "", nil, fmt.Errorf("store: generate key: %w", err)
	}
	newID, err := contracts.GenerateKeyID()
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

	rec := &contracts.APIKey{
		ID:             newID,
		OwnerAccountID: accountID,
		Name:           old.Name,
		Label:          contracts.KeyLabel(raw),
		KeyHash:        contracts.HashKey(raw),
		Disabled:       old.Disabled,
		LimitMicroUSD:  old.LimitMicroUSD,
		LimitReset:     contracts.NormalizeResetWindow(old.LimitReset),
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
func (s *Store) TouchAPIKey(id string, at time.Time) {
	if id == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, _ = s.pool.Exec(ctx, `UPDATE api_keys SET last_used_at = $1 WHERE id = $2`, at.UTC(), id)
}

// KeySpendSince returns total micro-USD charged to a key since `since` (UTC).
func (s *Store) KeySpendSince(keyID string, since time.Time) int64 {
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
func (s *Store) RevokeKey(key string) bool {
	h := contracts.HashKey(key)

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

// KeyCount returns the number of active API keys.
func (s *Store) KeyCount() int {
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
