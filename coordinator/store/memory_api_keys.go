package store

import (
	"fmt"
	"sort"
	"time"
)

// CreateKey generates a cryptographically random API key, stores it, and
// returns it. The key is unlinked to any account (legacy bootstrap helper).
func (s *MemoryStore) CreateKey() (string, error) {
	raw, _, err := s.CreateAPIKey("", APIKeyCreate{})
	return raw, err
}

// CreateKeyForAccount generates a new API key linked to a specific account.
func (s *MemoryStore) CreateKeyForAccount(accountID string) (string, error) {
	raw, _, err := s.CreateAPIKey(accountID, APIKeyCreate{})
	return raw, err
}

// CreateAPIKey mints a new API key with optional per-key limits.
func (s *MemoryStore) CreateAPIKey(accountID string, opts APIKeyCreate) (string, *APIKey, error) {
	raw, err := GenerateRawKey()
	if err != nil {
		return "", nil, err
	}
	id, err := GenerateKeyID()
	if err != nil {
		return "", nil, err
	}
	rec := &APIKey{
		ID:             id,
		OwnerAccountID: accountID,
		Name:           opts.Name,
		Label:          KeyLabel(raw),
		KeyHash:        sha256Hex(raw),
		LimitMicroUSD:  cloneInt64Ptr(opts.LimitMicroUSD),
		LimitReset:     NormalizeResetWindow(opts.LimitReset),
		RPMLimit:       cloneInt64Ptr(opts.RPMLimit),
		ITPMLimit:      cloneInt64Ptr(opts.ITPMLimit),
		OTPMLimit:      cloneInt64Ptr(opts.OTPMLimit),
		AllowedModels:  append([]string(nil), opts.AllowedModels...),
		SelfRouteOnly:  opts.SelfRouteOnly,
		ExpiresAt:      cloneTimePtr(opts.ExpiresAt),
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
func (s *MemoryStore) ValidateKey(key string) bool {
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
func (s *MemoryStore) GetKeyAccount(key string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if rec, ok := s.keyRecords[key]; ok {
		return rec.OwnerAccountID
	}
	return ""
}

// ValidateKeyFull returns the active status and owner account ID for an
// API key in a single lookup. Returns an error if the key does not exist.
func (s *MemoryStore) ValidateKeyFull(key string) (bool, string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.keyRecords[key]
	if !ok {
		return false, "", fmt.Errorf("key not found")
	}
	return !rec.Disabled, rec.OwnerAccountID, nil
}

// AuthenticateKey resolves a raw key to its active record for request auth.
func (s *MemoryStore) AuthenticateKey(rawKey string) (*APIKey, error) {
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
func (s *MemoryStore) ListAPIKeys(accountID string) ([]APIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]APIKey, 0)
	for _, rec := range s.keyRecords {
		if rec.OwnerAccountID != accountID || rec.ID == "" {
			continue
		}
		out = append(out, *cloneAPIKey(rec))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}

// GetAPIKeyByID returns a single key by ID, scoped to the owner.
func (s *MemoryStore) GetAPIKeyByID(accountID, id string) (*APIKey, error) {
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
	return cloneAPIKey(rec), nil
}

// UpdateAPIKey overwrites mutable fields of a key, scoped to the owner.
func (s *MemoryStore) UpdateAPIKey(accountID, id string, mutable APIKey) (*APIKey, error) {
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
	rec.LimitMicroUSD = cloneInt64Ptr(mutable.LimitMicroUSD)
	rec.LimitReset = NormalizeResetWindow(mutable.LimitReset)
	rec.RPMLimit = cloneInt64Ptr(mutable.RPMLimit)
	rec.ITPMLimit = cloneInt64Ptr(mutable.ITPMLimit)
	rec.OTPMLimit = cloneInt64Ptr(mutable.OTPMLimit)
	rec.AllowedModels = append([]string(nil), mutable.AllowedModels...)
	rec.SelfRouteOnly = mutable.SelfRouteOnly
	rec.ExpiresAt = cloneTimePtr(mutable.ExpiresAt)
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
func (s *MemoryStore) RotateAPIKey(accountID, id string) (string, *APIKey, error) {
	raw, err := GenerateRawKey()
	if err != nil {
		return "", nil, err
	}
	newID, err := GenerateKeyID()
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
	rec := &APIKey{
		ID:             newID,
		OwnerAccountID: accountID,
		Name:           old.Name,
		Label:          KeyLabel(raw),
		KeyHash:        sha256Hex(raw),
		Disabled:       old.Disabled,
		LimitMicroUSD:  cloneInt64Ptr(old.LimitMicroUSD),
		LimitReset:     NormalizeResetWindow(old.LimitReset),
		RPMLimit:       cloneInt64Ptr(old.RPMLimit),
		ITPMLimit:      cloneInt64Ptr(old.ITPMLimit),
		OTPMLimit:      cloneInt64Ptr(old.OTPMLimit),
		AllowedModels:  append([]string(nil), old.AllowedModels...),
		SelfRouteOnly:  old.SelfRouteOnly,
		ExpiresAt:      cloneTimePtr(old.ExpiresAt),
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
