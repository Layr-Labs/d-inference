package store

import (
	"context"
	"time"
)

// The in-memory store keeps the same durable copy so the dev/test path
// exercises the registry's persistence code without Postgres.

func (s *MemoryStore) cacheRoutingMapsLocked() {
	if s.cacheHolders == nil {
		s.cacheHolders = make(map[CacheHolderKey]CacheHolderRecord)
	}
	if s.cacheDemand == nil {
		s.cacheDemand = make(map[string]time.Time)
	}
}

func (s *MemoryStore) UpsertCacheHolders(ctx context.Context, records []CacheHolderRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, r := range records {
		if err := r.validate(); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cacheRoutingMapsLocked()
	for _, r := range records {
		key := r.HolderKey()
		if existing, ok := s.cacheHolders[key]; ok {
			s.cacheHolders[key] = laterHolder(existing, r)
		} else {
			s.cacheHolders[key] = r
		}
	}
	return nil
}

func (s *MemoryStore) DeleteCacheHolders(ctx context.Context, keys []CacheHolderKey) error {
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

func (s *MemoryStore) LoadCacheHolders(ctx context.Context, now time.Time) ([]CacheHolderRecord, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]CacheHolderRecord, 0, len(s.cacheHolders))
	for _, r := range s.cacheHolders {
		if r.ExpiresAt.After(now) {
			out = append(out, r)
		}
	}
	return out, nil
}

func (s *MemoryStore) UpsertCacheDemand(ctx context.Context, records []CacheDemandRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, r := range records {
		if err := r.validate(); err != nil {
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

func (s *MemoryStore) LoadCacheDemand(ctx context.Context, notBefore time.Time) ([]CacheDemandRecord, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]CacheDemandRecord, 0, len(s.cacheDemand))
	for key, seen := range s.cacheDemand {
		if !seen.Before(notBefore) {
			out = append(out, CacheDemandRecord{Key: key, SeenAt: seen})
		}
	}
	return out, nil
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
