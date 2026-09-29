package store

import (
	"context"
	"sort"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// The in-memory store keeps the same durable copy so the dev/test path
// exercises the registry's persistence code without Postgres.

func (s *MemoryStore) cacheRoutingMapsLocked() {
	if s.cacheHolders == nil {
		s.cacheHolders = make(map[crs.HolderKey]crs.HolderRecord)
	}
	if s.cacheDemand == nil {
		s.cacheDemand = make(map[string]time.Time)
	}
}

func (s *MemoryStore) UpsertCacheHolders(ctx context.Context, records []crs.HolderRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, r := range records {
		if err := r.Validate(); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cacheRoutingMapsLocked()
	for _, r := range records {
		key := r.HolderKey()
		if existing, ok := s.cacheHolders[key]; ok {
			s.cacheHolders[key] = crs.Later(existing, r)
		} else {
			s.cacheHolders[key] = r
		}
	}
	return nil
}

func (s *MemoryStore) DeleteCacheHolders(ctx context.Context, keys []crs.HolderKey) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cacheRoutingMapsLocked()
	for _, k := range keys {
		delete(s.cacheHolders, k)
	}
	return nil
}

func (s *MemoryStore) LoadCacheHolders(ctx context.Context, now time.Time, ttl time.Duration, limit int) ([]crs.HolderRecord, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]crs.HolderRecord, 0, len(s.cacheHolders))
	for _, r := range s.cacheHolders {
		// Effective expiry under the current TTL, applied before the order
		// and the cap exactly as the Postgres query does.
		if ttl > 0 {
			if clamp := r.UpdatedAt.Add(ttl); clamp.Before(r.ExpiresAt) {
				r.ExpiresAt = clamp
			}
		}
		if r.ExpiresAt.After(now) {
			out = append(out, r)
		}
	}
	// Longest-lived first, then a stable key order, matching the Postgres
	// ORDER BY so a capped restore keeps the same rows on both backends.
	sort.Slice(out, func(i, j int) bool {
		if !out[i].ExpiresAt.Equal(out[j].ExpiresAt) {
			return out[i].ExpiresAt.After(out[j].ExpiresAt)
		}
		if out[i].Key != out[j].Key {
			return out[i].Key < out[j].Key
		}
		return out[i].CacheEpoch < out[j].CacheEpoch
	})
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *MemoryStore) UpsertCacheDemand(ctx context.Context, records []crs.DemandRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, r := range records {
		if err := r.Validate(); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cacheRoutingMapsLocked()
	for _, r := range records {
		if existing, ok := s.cacheDemand[r.Key]; !ok || r.SeenAt.After(existing) {
			s.cacheDemand[r.Key] = r.SeenAt
		}
	}
	return nil
}

func (s *MemoryStore) LoadCacheDemand(ctx context.Context, notBefore, notAfter time.Time, limit int) ([]crs.DemandRecord, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]crs.DemandRecord, 0, len(s.cacheDemand))
	for key, seen := range s.cacheDemand {
		if !seen.Before(notBefore) && !seen.After(notAfter) {
			out = append(out, crs.DemandRecord{Key: key, SeenAt: seen})
		}
	}
	// Newest first, then key, matching the Postgres ORDER BY.
	sort.Slice(out, func(i, j int) bool {
		if !out[i].SeenAt.Equal(out[j].SeenAt) {
			return out[i].SeenAt.After(out[j].SeenAt)
		}
		return out[i].Key < out[j].Key
	})
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *MemoryStore) CacheRoutingKeyFingerprint(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cacheRoutingFingerprint, nil
}

func (s *MemoryStore) ResetCacheRoutingState(ctx context.Context, fingerprint string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cacheHolders = make(map[crs.HolderKey]crs.HolderRecord)
	s.cacheDemand = make(map[string]time.Time)
	s.cacheRoutingFingerprint = fingerprint
	return nil
}

func (s *MemoryStore) PruneCacheRoutingState(ctx context.Context, now, demandNotBefore time.Time) (int64, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cacheRoutingMapsLocked()
	var removed int64
	for key, r := range s.cacheHolders {
		if !r.ExpiresAt.After(now) {
			delete(s.cacheHolders, key)
			removed++
		}
	}
	for key, seen := range s.cacheDemand {
		if seen.Before(demandNotBefore) {
			delete(s.cacheDemand, key)
			removed++
		}
	}
	return removed, nil
}
