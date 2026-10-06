package memory

import (
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// keySpend tracks per-key spend for cap enforcement. Day buckets (UTC date →
// micro-USD) let us answer daily/weekly/monthly windowed queries cheaply
// (≤31 buckets retained); lifetime is a running total. Buckets older than the
// retention horizon are pruned lazily on write.
type keySpend struct {
	lifetime int64
	days     map[string]int64 // "2006-01-02" (UTC) → micro-USD
}

const keySpendRetentionDays = 40

// CreateKeyForAccount generates a new API key linked to a specific account.
func (s *MemoryStore) CreateKeyForAccount(accountID string) (string, error) {
	raw, _, err := s.CreateAPIKey(accountID, store.APIKeyCreate{})
	return raw, err
}

// CreateAPIKey mints a new API key with optional per-key limits.
func (s *MemoryStore) CreateAPIKey(accountID string, opts store.APIKeyCreate) (string, *store.APIKey, error) {
	raw, err := store.GenerateRawKey()
	if err != nil {
		return "", nil, err
	}
	id, err := store.GenerateKeyID()
	if err != nil {
		return "", nil, err
	}
	rec := &store.APIKey{
		ID:             id,
		OwnerAccountID: accountID,
		Name:           opts.Name,
		Label:          store.KeyLabel(raw),
		KeyHash:        store.HashKey(raw),
		LimitMicroUSD:  store.CloneInt64Ptr(opts.LimitMicroUSD),
		LimitReset:     store.NormalizeResetWindow(opts.LimitReset),
		RPMLimit:       store.CloneInt64Ptr(opts.RPMLimit),
		ITPMLimit:      store.CloneInt64Ptr(opts.ITPMLimit),
		OTPMLimit:      store.CloneInt64Ptr(opts.OTPMLimit),
		AllowedModels:  append([]string(nil), opts.AllowedModels...),
		SelfRouteOnly:  opts.SelfRouteOnly,
		ExpiresAt:      store.CloneTimePtr(opts.ExpiresAt),
		CreatedAt:      time.Now().UTC(),
	}
	s.mu.Lock()
	s.keyRecords[raw] = rec
	s.keysByID[id] = raw
	s.mu.Unlock()
	out := *rec
	return raw, &out, nil
}

// GetKeyAccount returns the account ID that owns this key, or "" if unlinked.
func (s *MemoryStore) GetKeyAccount(key string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if rec, ok := s.keyRecords[key]; ok && rec.DeletedAt == nil {
		return rec.OwnerAccountID
	}
	return ""
}

// AuthenticateKey resolves a raw key to its active record for request auth.
func (s *MemoryStore) AuthenticateKey(rawKey string) (*store.APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.keyRecords[rawKey]
	if !ok || rec.DeletedAt != nil {
		return nil, fmt.Errorf("key not found")
	}
	if rec.Disabled {
		return nil, fmt.Errorf("key disabled")
	}
	if rec.ExpiresAt != nil && time.Now().After(*rec.ExpiresAt) {
		return nil, fmt.Errorf("key expired")
	}
	out := cloneAPIKey(rec)
	return out, nil
}

// RevokeKey deactivates a key (soft-disable), matching PostgresStore semantics
// and the Store interface contract ("deactivates a key"). The record is kept so
// it still appears in ListAPIKeys as disabled. Returns true only if the key
// existed AND was active (a second revoke returns false). By-ID deletion
// (RevokeAPIKeyByID) is the hard-delete path.
func (s *MemoryStore) RevokeKey(key string) bool {
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
func (s *MemoryStore) ListAPIKeys(accountID string) ([]store.APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]store.APIKey, 0)
	for _, rec := range s.keyRecords {
		if rec.OwnerAccountID != accountID || rec.ID == "" || rec.DeletedAt != nil {
			continue
		}
		out = append(out, *cloneAPIKey(rec))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}

// GetAPIKeyByID returns a single key by ID, scoped to the owner.
func (s *MemoryStore) GetAPIKeyByID(accountID, id string) (*store.APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return nil, fmt.Errorf("key not found")
	}
	rec, ok := s.keyRecords[raw]
	if !ok || rec.OwnerAccountID != accountID || rec.DeletedAt != nil {
		return nil, fmt.Errorf("key not found")
	}
	return cloneAPIKey(rec), nil
}

// UpdateAPIKey overwrites mutable fields of a key, scoped to the owner.
func (s *MemoryStore) UpdateAPIKey(accountID, id string, mutable store.APIKey) (*store.APIKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, ok := s.keysByID[id]
	if !ok {
		return nil, fmt.Errorf("key not found")
	}
	rec, ok := s.keyRecords[raw]
	if !ok || rec.OwnerAccountID != accountID || rec.DeletedAt != nil {
		return nil, fmt.Errorf("key not found")
	}
	rec.Name = mutable.Name
	rec.Disabled = mutable.Disabled
	rec.LimitMicroUSD = store.CloneInt64Ptr(mutable.LimitMicroUSD)
	rec.LimitReset = store.NormalizeResetWindow(mutable.LimitReset)
	rec.RPMLimit = store.CloneInt64Ptr(mutable.RPMLimit)
	rec.ITPMLimit = store.CloneInt64Ptr(mutable.ITPMLimit)
	rec.OTPMLimit = store.CloneInt64Ptr(mutable.OTPMLimit)
	rec.AllowedModels = append([]string(nil), mutable.AllowedModels...)
	rec.SelfRouteOnly = mutable.SelfRouteOnly
	rec.ExpiresAt = store.CloneTimePtr(mutable.ExpiresAt)
	return cloneAPIKey(rec), nil
}

// RevokeAPIKeyByID permanently deletes a key by ID, scoped to the owner.
func (s *MemoryStore) RevokeAPIKeyByID(accountID, id string) error {
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
func (s *MemoryStore) RotateAPIKey(accountID, id string) (string, *store.APIKey, error) {
	raw, err := store.GenerateRawKey()
	if err != nil {
		return "", nil, err
	}
	newID, err := store.GenerateKeyID()
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
	if !ok || old.OwnerAccountID != accountID || old.DeletedAt != nil {
		return "", nil, fmt.Errorf("key not found")
	}
	rec := &store.APIKey{
		ID:             newID,
		OwnerAccountID: accountID,
		Name:           old.Name,
		Label:          store.KeyLabel(raw),
		KeyHash:        store.HashKey(raw),
		Disabled:       old.Disabled,
		LimitMicroUSD:  store.CloneInt64Ptr(old.LimitMicroUSD),
		LimitReset:     store.NormalizeResetWindow(old.LimitReset),
		RPMLimit:       store.CloneInt64Ptr(old.RPMLimit),
		ITPMLimit:      store.CloneInt64Ptr(old.ITPMLimit),
		OTPMLimit:      store.CloneInt64Ptr(old.OTPMLimit),
		AllowedModels:  append([]string(nil), old.AllowedModels...),
		SelfRouteOnly:  old.SelfRouteOnly,
		ExpiresAt:      store.CloneTimePtr(old.ExpiresAt),
		CreatedAt:      time.Now().UTC(),
	}
	delete(s.keyRecords, oldRaw)
	delete(s.keysByID, id)
	s.keyRecords[raw] = rec
	s.keysByID[newID] = raw
	return raw, cloneAPIKey(rec), nil
}

// TouchAPIKey records that a key was used at the given time.
func (s *MemoryStore) TouchAPIKey(id string, at time.Time) {
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
func (s *MemoryStore) KeySpendSince(keyID string, since time.Time) int64 {
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
func (s *MemoryStore) addKeySpendLocked(keyID string, amount int64, at time.Time) {
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

// cloneAPIKey returns a deep copy of a key record so callers can never mutate
// the store's internal state through the returned pointer.
func cloneAPIKey(rec *store.APIKey) *store.APIKey {
	if rec == nil {
		return nil
	}
	cp := *rec
	cp.LimitMicroUSD = store.CloneInt64Ptr(rec.LimitMicroUSD)
	cp.RPMLimit = store.CloneInt64Ptr(rec.RPMLimit)
	cp.ITPMLimit = store.CloneInt64Ptr(rec.ITPMLimit)
	cp.OTPMLimit = store.CloneInt64Ptr(rec.OTPMLimit)
	cp.ExpiresAt = store.CloneTimePtr(rec.ExpiresAt)
	cp.LastUsedAt = store.CloneTimePtr(rec.LastUsedAt)
	cp.AllowedModels = append([]string(nil), rec.AllowedModels...)
	return &cp
}
