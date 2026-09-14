package memory

import (
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
)

// CreateKey generates a cryptographically random API key, stores it, and
// returns it. The key is unlinked to any account (legacy bootstrap helper).
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
		return "", nil, err
	}
	id, err := contracts.GenerateKeyID()
	if err != nil {
		return "", nil, err
	}
	rec := &contracts.APIKey{
		ID:             id,
		OwnerAccountID: accountID,
		Name:           opts.Name,
		Label:          contracts.KeyLabel(raw),
		KeyHash:        contracts.HashKey(raw),
		LimitMicroUSD:  recordutil.CloneInt64Ptr(opts.LimitMicroUSD),
		LimitReset:     contracts.NormalizeResetWindow(opts.LimitReset),
		RPMLimit:       recordutil.CloneInt64Ptr(opts.RPMLimit),
		ITPMLimit:      recordutil.CloneInt64Ptr(opts.ITPMLimit),
		OTPMLimit:      recordutil.CloneInt64Ptr(opts.OTPMLimit),
		AllowedModels:  append([]string(nil), opts.AllowedModels...),
		SelfRouteOnly:  opts.SelfRouteOnly,
		ExpiresAt:      recordutil.CloneTimePtr(opts.ExpiresAt),
		CreatedAt:      time.Now().UTC(),
	}
	s.mu.Lock()
	s.keyRecords[raw] = rec
	s.keysByID[id] = raw
	s.mu.Unlock()
	out := *rec
	return raw, &out, nil
}

// ValidateKey returns true if the given key exists, is active, and is not
// expired. Expiry is enforced here (not just in AuthenticateKey) so callers
// like telemetry attribution don't treat an expired key as a live account.
func (s *Store) ValidateKey(key string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.keyRecords[key]
	if !ok || rec.Disabled {
		return false
	}
	if rec.ExpiresAt != nil && time.Now().After(*rec.ExpiresAt) {
		return false
	}
	return true
}

// GetKeyAccount returns the account ID that owns this key, or "" if unlinked.
func (s *Store) GetKeyAccount(key string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if rec, ok := s.keyRecords[key]; ok {
		return rec.OwnerAccountID
	}
	return ""
}

// ValidateKeyFull returns the active status and owner account ID for an
// API key in a single lookup. Returns an error if the key does not exist.
func (s *Store) ValidateKeyFull(key string) (bool, string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.keyRecords[key]
	if !ok {
		return false, "", fmt.Errorf("key not found")
	}
	return !rec.Disabled, rec.OwnerAccountID, nil
}

// AuthenticateKey resolves a raw key to its active record for request auth.
func (s *Store) AuthenticateKey(rawKey string) (*contracts.APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.keyRecords[rawKey]
	if !ok {
		return nil, fmt.Errorf("key not found")
	}
	if rec.Disabled {
		return nil, fmt.Errorf("key disabled")
	}
	if rec.ExpiresAt != nil && time.Now().After(*rec.ExpiresAt) {
		return nil, fmt.Errorf("key expired")
	}
	out := recordutil.CloneAPIKey(rec)
	return out, nil
}

// RevokeKey deactivates a key (soft-disable), matching PostgresStore semantics
// and the Store interface contract ("deactivates a key"). The record is kept so
// it still appears in ListAPIKeys as disabled. Returns true only if the key
// existed AND was active (a second revoke returns false). By-ID deletion
// (RevokeAPIKeyByID) is the hard-delete path.
func (s *Store) RevokeKey(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.keyRecords[key]
	if !ok || rec.Disabled {
		return false
	}
	rec.Disabled = true
	return true
}

// ListAPIKeys returns all keys owned by an account, newest first.
func (s *Store) ListAPIKeys(accountID string) ([]contracts.APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]contracts.APIKey, 0)
	for _, rec := range s.keyRecords {
		if rec.OwnerAccountID != accountID || rec.ID == "" {
			continue
		}
		out = append(out, *recordutil.CloneAPIKey(rec))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}

// GetAPIKeyByID returns a single key by ID, scoped to the owner.
func (s *Store) GetAPIKeyByID(accountID, id string) (*contracts.APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return nil, fmt.Errorf("key not found")
	}
	rec, ok := s.keyRecords[raw]
	if !ok || rec.OwnerAccountID != accountID {
		return nil, fmt.Errorf("key not found")
	}
	return recordutil.CloneAPIKey(rec), nil
}

// UpdateAPIKey overwrites mutable fields of a key, scoped to the owner.
func (s *Store) UpdateAPIKey(accountID, id string, mutable contracts.APIKey) (*contracts.APIKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return nil, fmt.Errorf("key not found")
	}
	rec, ok := s.keyRecords[raw]
	if !ok || rec.OwnerAccountID != accountID {
		return nil, fmt.Errorf("key not found")
	}
	rec.Name = mutable.Name
	rec.Disabled = mutable.Disabled
	rec.LimitMicroUSD = recordutil.CloneInt64Ptr(mutable.LimitMicroUSD)
	rec.LimitReset = contracts.NormalizeResetWindow(mutable.LimitReset)
	rec.RPMLimit = recordutil.CloneInt64Ptr(mutable.RPMLimit)
	rec.ITPMLimit = recordutil.CloneInt64Ptr(mutable.ITPMLimit)
	rec.OTPMLimit = recordutil.CloneInt64Ptr(mutable.OTPMLimit)
	rec.AllowedModels = append([]string(nil), mutable.AllowedModels...)
	rec.SelfRouteOnly = mutable.SelfRouteOnly
	rec.ExpiresAt = recordutil.CloneTimePtr(mutable.ExpiresAt)
	return recordutil.CloneAPIKey(rec), nil
}

// RevokeAPIKeyByID permanently deletes a key by ID, scoped to the owner.
func (s *Store) RevokeAPIKeyByID(accountID, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return fmt.Errorf("key not found")
	}
	rec, ok := s.keyRecords[raw]
	if !ok || rec.OwnerAccountID != accountID {
		return fmt.Errorf("key not found")
	}
	delete(s.keyRecords, raw)
	delete(s.keysByID, id)
	return nil
}

// RotateAPIKey atomically replaces a key (see Store interface).
func (s *Store) RotateAPIKey(accountID, id string) (string, *contracts.APIKey, error) {
	raw, err := contracts.GenerateRawKey()
	if err != nil {
		return "", nil, err
	}
	newID, err := contracts.GenerateKeyID()
	if err != nil {
		return "", nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	oldRaw, ok := s.keysByID[id]
	if !ok {
		return "", nil, fmt.Errorf("key not found")
	}
	old, ok := s.keyRecords[oldRaw]
	if !ok || old.OwnerAccountID != accountID {
		return "", nil, fmt.Errorf("key not found")
	}
	rec := &contracts.APIKey{
		ID:             newID,
		OwnerAccountID: accountID,
		Name:           old.Name,
		Label:          contracts.KeyLabel(raw),
		KeyHash:        contracts.HashKey(raw),
		Disabled:       old.Disabled,
		LimitMicroUSD:  recordutil.CloneInt64Ptr(old.LimitMicroUSD),
		LimitReset:     contracts.NormalizeResetWindow(old.LimitReset),
		RPMLimit:       recordutil.CloneInt64Ptr(old.RPMLimit),
		ITPMLimit:      recordutil.CloneInt64Ptr(old.ITPMLimit),
		OTPMLimit:      recordutil.CloneInt64Ptr(old.OTPMLimit),
		AllowedModels:  append([]string(nil), old.AllowedModels...),
		SelfRouteOnly:  old.SelfRouteOnly,
		ExpiresAt:      recordutil.CloneTimePtr(old.ExpiresAt),
		CreatedAt:      time.Now().UTC(),
	}
	delete(s.keyRecords, oldRaw)
	delete(s.keysByID, id)
	s.keyRecords[raw] = rec
	s.keysByID[newID] = raw
	return raw, recordutil.CloneAPIKey(rec), nil
}

// TouchAPIKey records that a key was used at the given time.
func (s *Store) TouchAPIKey(id string, at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return
	}
	if rec, ok := s.keyRecords[raw]; ok {
		t := at.UTC()
		rec.LastUsedAt = &t
	}
}

// KeySpendSince returns total micro-USD charged to a key since `since` (UTC).
func (s *Store) KeySpendSince(keyID string, since time.Time) int64 {
	if keyID == "" {
		return 0
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	ks, ok := s.keySpend[keyID]
	if !ok {
		return 0
	}
	if since.IsZero() {
		return ks.lifetime
	}
	startDay := since.UTC().Format("2006-01-02")
	var total int64
	for day, amt := range ks.days {
		if day >= startDay {
			total += amt
		}
	}
	return total
}

// addKeySpendLocked increments the per-key spend accumulator. Caller holds s.mu.
func (s *Store) addKeySpendLocked(keyID string, amount int64, at time.Time) {
	ks, ok := s.keySpend[keyID]
	if !ok {
		ks = &keySpend{days: make(map[string]int64)}
		s.keySpend[keyID] = ks
	}
	ks.lifetime += amount
	day := at.UTC().Format("2006-01-02")
	ks.days[day] += amount
	// Prune buckets older than the retention horizon to bound memory.
	if len(ks.days) > keySpendRetentionDays {
		cutoff := at.UTC().AddDate(0, 0, -keySpendRetentionDays).Format("2006-01-02")
		for d := range ks.days {
			if d < cutoff {
				delete(ks.days, d)
			}
		}
	}
}

// KeyCount returns the number of active API keys.
func (s *Store) KeyCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for _, rec := range s.keyRecords {
		if !rec.Disabled {
			n++
		}
	}
	return n
}
